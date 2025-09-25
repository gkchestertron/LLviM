" get setting overrides
if !exists("g:llvim_api_url")
    let g:llvim_api_url= "127.0.0.1:8080/v1/chat/completions"
endif
if !exists("g:llvim_overrides")
   let g:llvim_overrides = {}
endif
const s:querydata = {"n_predict": -1, "stream": v:true }
const s:curlcommand = ['curl','--data-raw', "{}", '--silent', '--no-buffer', '--request', 'POST', '--url', g:llvim_api_url, '--header', "Content-Type: application/json"]
let s:linedict = {}
let s:skipping_fence = 0
let s:echo_content = v:false
let s:echo_content_message = ''
let s:tool_calls = []
let s:tools = [
      \ {
      \   'type': 'function',
      \   'function': {
      \     'name': 'replace_lines_in_buffer',
      \     'description': 'Replace a range of lines in a buffer with an array of new nlines. Use when asked to edit code, use this tool to replace one section at a time. Files will be provided with line numbers for convenience. Do not rewrite entire files.',
      \     'parameters': {
      \       'type': 'object',
      \       'properties': {
      \         'buffer_name': {'type': 'string', 'description': 'Name of the buffer to modify'},
      \         'start': {'type': 'integer', 'description': 'Starting line number (1-based)'},
      \         'end': {'type': 'integer', 'description': 'Ending line number (1-based)'},
      \         'lines': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Array of new lines to insert in place of old lines. Do not separate lines with new line characters, pass each as an item in the lines array.'}
      \       },
      \       'required': ['buffer_name', 'start', 'end', 'lines']
      \     }
      \   },
      \ },
      \ {
      \   'type': 'function',
      \   'function': {
      \     'name': 'execute_vim_command',
      \     'description': 'Allows assistant to provide a command to be executed by vim with `:execute "command". Pass only the command, not "execute". Avoid providing harmful commands. Only call this function if user specifically instructs you to do so. Do not use this function if the user asks you to write code or asks a question. Assume there is already a text selection. Do not operate on whole file (e.g. %s) unless specifically instructed.',
      \     'parameters': {
      \       'type': 'object',
      \       'properties': {
      \         'command': {'type': 'string', 'description': 'series of characters/commands to pass to :execute'}
      \       },
      \       'required': ['command']
      \     }
      \   }
      \ }
      \ ]

" handle switching to and from context buffer
function! llvim#openOrClosePromptBuffer()
  " hide the buffer if we're in it
  if bufname("%") == "/tmp/llvim-prompt"
    execute "w|hide"

  " Check if the buffer is already open and switch to it
  elseif bufexists("/tmp/llvim-prompt")
    let l:bufn = bufnr("/tmp/llvim-prompt")

    " if it's hidden, make a new split and unhide it
    if len(win_findbuf(l:bufn)) == 0
      execute "vnew"
      execute "b " . l:bufn

    " already open, jump to it
    else
      execute "wincmd w" . "|wincmd" . bufwinnr(l:bufn)
    endif

  " no buffer, let's make one
  else
    execute "vnew|e /tmp/llvim-prompt"
  endif
endfunction

" put last given code block in default register
function llvim#extractLastCodeBlock(bufn)
  " Define the path to the file
  let l:lines = getbufline(bufnr('/tmp/llvim-prompt'), 1, '$')

  " Initialize variables
  let l:block_number = 1
  let l:in_block = 0
  let l:code_block = []

  " Loop through each line in the file and capture the code blocks
  for l:line in l:lines
    " Check for the start or end of a block
    if l:line =~# '^```'
      " at the end of a block - join all the lines and put in a register
      if l:in_block
        let l:in_block = 0
        let l:block = join(l:code_block, "\n")
        call setreg(l:block_number, l:block)
        call setreg('"', l:block)
        let l:block_number += 1
        let l:code_block = []

      " starting a block
      else
        let l:in_block = 1
      endif

    " in a block - capture the line
    elseif l:in_block
      call add(l:code_block, l:line)
    endif
  endfor

  " Capture the last block if any
  if l:in_block
      echo 'copying block'
      let l:block = join(l:code_block, "\n")
      call setreg('"', l:block)
  endif
endfunction

" save selected lines for context - only called from file, not context buffer
function! llvim#saveHighlightedText()
  " get syntax and selected text
  let stx = &syntax

  " open and clear the buffer
  call llvim#openOrClosePromptBuffer()

  " Append each line with proper line breaks and code fence
  call append(line('$'), "```" . stx)
  for line in lines
    call append(line('$'), line)
  endfor
  call append(line('$'), "```")
endfunction

func! llvim#addHighlightedTexttoContext()
  execute 'normal "aY'
  let l:selection = getreg("a")
  let l:lines = split(l:selection, "\n")

  let l:start_line = line('.')
  
  " Add line numbers to each line
  let l:numbered_lines = []
  for i in range(len(l:lines))
    let l:numbered_lines += [printf("%4d: %s", l:start_line + i, l:lines[i])]
  endfor

  " get syntax and selected text
  let stx = &syntax

  " open and clear the buffer
  call llvim#openOrClosePromptBuffer()

  " Append each line with proper line breaks and code fence
  call append(line('$'), 'selection from file: ' . expand('%'))
  call append(line('$'), "```" . stx)
  for line in l:numbered_lines
    call append(line('$'), line)
  endfor
  call append(line('$'), "```")
endfunc

" handle data coming back from the model
func s:callbackHandler(bufn, channel, msg)
  let l:bufn = a:bufn

  " stop job and return if the buffer we're writing to went away
  if len(win_findbuf(l:bufn)) == 0
    if exists("b:job")
      if job_status(b:job) == "run"
        call job_stop(b:job)
      endif
    endif
    return
  endif

  " skip empty messages and unnest if under 'data: '
  if len(a:msg) < 3
    return
  elseif a:msg[0] == "d"
    let l:msg = a:msg[6:-1]
  else
    let l:msg = a:msg
  endif

  if l:msg[0:6] == '[DONE]'
    return
  endif

  " decode message and split into lines
  let l:decoded_msg = json_decode(l:msg)
  let l:newtext = []

  " handle tool_calls
  if has_key(l:decoded_msg['choices'][0]['delta'], 'tool_calls')
    let l:tool_calls = l:decoded_msg['choices'][0]['delta']['tool_calls']
    for l:tool_call in l:tool_calls
      if has_key(l:tool_call, 'id')
        call add(s:tool_calls, l:tool_call)
      elseif has_key(l:tool_call, 'index')
        let s:tool_calls[l:tool_call['index']]['function']['arguments'] .= l:tool_call['function']['arguments']
      endif
    endfor
    return
  endif

  if has_key(l:decoded_msg['choices'][0]['delta'], 'content')
    " skip null values
    if l:decoded_msg['choices'][0]['delta']['content'] == v:null
      return
    endif
    let l:newtext = split(l:decoded_msg['choices'][0]['delta']['content'], "\n", 1)
  else
    if has_key(l:decoded_msg['choices'][0], 'finish_reason') && l:decoded_msg['choices'][0]['finish_reason'] == 'tool_calls'
      echom 'tool calls'
      echom s:tool_calls
      echom 'content'
      echom s:echo_content_message
      let s:echo_content_message = ''
      " execute tool_calls
      for tool_call in s:tool_calls
        if tool_call['function']['name'] == 'execute_vim_command'
          let l:arguments = json_decode(tool_call['function']['arguments'])
          execute l:arguments['command']
        endif
        if tool_call['function']['name'] == 'replace_lines_in_buffer'
          let l:arguments = json_decode(tool_call['function']['arguments'])
          call llvim#ReplaceLinesInBuffer(arguments['buffer_name'], arguments['start'], arguments['end'], arguments['lines'])
        endif
      endfor
      let s:echo_content = v:false
      return
    endif
    if l:decoded_msg['choices'][0]['finish_reason'] == 'stop'
      let s:echo_content = v:false
      call llvim#extractLastCodeBlock(a:bufn)
      echo "Finished Generation"
    endif
    return
  endif

  if s:echo_content == v:true
    let s:echo_content_message .= join(l:newtext, "\n")
    return
  endif

  " append the first line of message to the starting line in the file or buffer
  " strip code fences and empty first line if in file
  if len(l:newtext) > 0
    if (bufname(l:bufn) != "/tmp/llvim-prompt" && l:newtext[0] =~# '^\s*```') || s:skipping_fence == 1
      let s:skipping_fence = 1
    else
      call setbufline(l:bufn, s:linedict[l:bufn], getbufline(l:bufn, s:linedict[l:bufn])[0] .. newtext[0])
    endif
  else
    echo "nothing genned"
  endif

  " Append subsequent lines to the file or buffer after the starting line
  " strip code fences if in file
  " and update the line pointer for the next line
  if len(l:newtext) > 1
    for l:line in newtext[1:-1]
      if s:skipping_fence == 1
        let s:skipping_fence = 0
        continue
      endif
      let l:result = appendbufline(l:bufn, s:linedict[l:bufn], l:line)
      let s:linedict[l:bufn] = s:linedict[l:bufn] + 1
    endfor
  endif

  " done
  if has_key(l:decoded_msg, "stop") && l:decoded_msg.stop
    let s:skipping_fence = 0
    call llvim#extractLastCodeBlock(a:bufn)
    echo "Finished generation"
  endif
endfunction

func llvim#test()
  let l:line = '```markdown'
  if l:line !~# '\s*^```'
    echo 'matches'
  endif
endfunc

" build context based on, uh... context and send to model for generation
func llvim#doLlamaGen()
  " stop running completion task if it exists
  if exists("b:job")
    if job_status(b:job) == "run"
      call job_stop(b:job)
      return
    endif
  endif

  " get current buffer and line
  let l:cbuffer = bufnr("%")
  let l:buflines = getbufline(l:cbuffer, line("."))

  " overwrite temp context file with all open files
  call writefile([""], "/tmp/llvim-context")
  for buf in filter(getbufinfo({'bufloaded':1}), {v -> len(v:val['windows'])})
    let filename = buf.name
    if !filereadable(filename) || filename == "/tmp/llvim-prompt" || filename == "/private/tmp/llvim-prompt"
      continue
    endif
    let lines = readfile(filename)
    call writefile([filename, "==========", "\n"], "/tmp/llvim-context", "a")
    call writefile(lines, "/tmp/llvim-context", "a")
    call writefile(["==========", "\n"], "/tmp/llvim-context", "a")
  endfor

  " handle overriding settings
  let l:querydata = copy(s:querydata)
  call extend(l:querydata, g:llvim_overrides)
  if exists("w:llvim_overrides")
    call extend(l:querydata, w:llvim_overrides)
  endif
  if exists("b:llvim_overrides")
    call extend(l:querydata, b:llvim_overrides)
  endif
  if l:buflines[0][0:1] == '!*'
    let l:userdata = json_decode(l:buflines[0][2:-1])
    call extend(l:querydata, l:userdata)
    let l:buflines = l:buflines[1:-1]
  endif

  " insert mode
  if mode() ==# "i"

    " in file - send default register and current line
    if bufname("%") != "/tmp/llvim-prompt"
      stopinsert
      echo "sending default register and current line for generation"
      sleep 500m

      " get default register, syntax, and current line
      let l:selectedText = getreg('"')
      let l:buflines = join(getbufline(l:cbuffer, line('.')), "\n")
      let stx = &syntax

      " clear current line
      call setbufline(l:cbuffer, line('.'), "")

      " save line number for callback
      let s:linedict[l:cbuffer] = line('.')

      " build up and set context for generation
      let l:baseprompt = "You are a helpful coding assistant that rewrites " . stx . " code samples according to user instructions. Do not explain outside of inline comments. Add the same number of spaces at the beginning of each line as in the given code sample to match indentation. Do not return in code blocks. Do not return the instructions. Return just the raw code as if you are typing it into a text editor. Return only the block(s) asked for unless specifically asked to rewrite a whole file."
      let l:context = "```" . stx . "\n" . l:selectedText . "```\n" . l:buflines
      let l:querydata.messages = [ {'role': 'system', 'content': l:baseprompt}, {'role': 'user', 'content': l:context} ]

    " in context buffer - send up to current line
    else
      stopinsert
      echo "sending up to current line for generation"
      sleep 500m

      " add empty lines, so we have line breaks between user and assistant
      let l:failed = appendbufline(l:cbuffer, line('.'), ['', '', '', ''])

      " get all lines up to cursor
      let l:buflines = join(getbufline(l:cbuffer, 1, line('.')), "\n")

      " save the line number for callback
      let s:linedict[l:cbuffer] = line('.') + 2

      "move cursor to after where it's gonna insert, so we get to watch it stream in
      call cursor(line('.') + 4, 0)

      let l:baseprompt = "You are a helpful coding assistant operating inside a vim text editor. You can answer questions, give code examples, control the editor through vim commands, and replace text in buffers. Keep your explanations concise and return code samples in labeled code fences. Do not use tools/functions when asked to write code or asked a question. Only call tools/functions when explicitly asked to do so."

      call llvim#callModel(l:baseprompt, l:buflines, [], [])
      return

      " set the prompt string
      let l:querydata.messages = [{'role': 'system', 'content': l:baseprompt}, {'role': 'user', 'content': l:buflines}]
    endif

  " normal mode
  elseif mode() ==# "n"

    " in file - send default register, current line, and all open files
    if bufname("%") != "/tmp/llvim-prompt"
      echo "sending current line, default register, and all open files for generation"
      sleep 500m

      " get default register and current line
      let l:selectedText = getreg('"')
      let l:buflines = join(getbufline(l:cbuffer, line('.')), "\n")

      " clear current line
      call setbufline(l:cbuffer, line('.'), "")

      " save the line number for callback
      let s:linedict[l:cbuffer] = line('.')

      " build and set context
      let stx = &syntax
      let context = join(readfile("/tmp/llvim-context"), "\n")
      let l:baseprompt = "You are a helpful coding assistant. Do not explain outside of inline comments. Add the same number of spaces at the beginning of each line as in the sample to match indentation. Do not return in code blocks. Return just the raw code as if you are typing it into a text editor. Return only the block(s) asked for in user instructions unless specifically asked to rewrite a whole file."

      let l:prompt = "Rewrite and return the " . stx . " selected text above according to the instructions below. Use the preceding files for context."
      let l:querydata.messages = [ {'role': 'system', 'content': l:baseprompt}, {'role': 'user', 'content': context}, {'role': 'user', 'content': '=======' . l:selectedText . '======='}, {'role': 'user', 'content': l:prompt}, {'role': 'user', 'content': "=========" . l:buflines . "========="}]

    " in context buffer - send whole buffer and all open files
    else
      echo "sending all files and buffer for generation"
      sleep 500m

      " build and set the context for generation
      let context = join(readfile("/tmp/llvim-context"), "\n")
      let l:buflines = getbufline(l:cbuffer, 1, '$')
      let l:baseprompt = "You are a helpful coding assistant. Keep your explanations concise and return code samples in labeled code fences."

      let l:querydata.messages = [ {'role': 'system', 'content': l:baseprompt}, {'role': 'user', 'content': context}, {'role': 'user', 'content': join(l:buflines, "\n")}]

      " Store the line number for callback
      let s:linedict[l:cbuffer] = line('$') + 1

      " add lines and move cursor so we can watch it stream
      call appendbufline(l:cbuffer, line('$'), ['', '', ''])
      call cursor(line('$'), 0)
    endif

  " visual mode 
  else
    " in file - clear buffer and paste in selected lines
    if bufname("%") != "/tmp/llvim-prompt"
      call llvim#addHighlightedTexttoContext()
      return
      let l:failed = appendbufline(l:cbuffer, line('$'), '')
      normal! G$
      return

    " in buffer - just send selection
    else
      " yank currently selected lines
      execute 'normal "aY'
      let l:selectedText = getreg("a")

      echo "sending selection for generation"
      sleep 500m

      " Get the position of the end of the selected text
      " getpos("'>")[1:2] returns the line and column number of the end of the selection
      let [l:line_end, l:column_end] = getpos("'>")[1:2]

      " Append an empty line to the current buffer at the end of the selected text
      let l:failed = appendbufline(l:cbuffer, l:line_end, '')

      " save position for callback
      let s:linedict[l:cbuffer] = l:line_end + 1

      let l:baseprompt = "Always label the language of any code fences/snippets/samples/blocks after the backticks (e.g. ```python). Return only the line, lines or function asked for in the code block. Concisely comment your code."

      " Join the user prompt and the assistant response into a single string
      let l:querydata.messages = [{'role': 'system', 'content': l:baseprompt}, {'role': 'user', 'content': l:selectedText}])
    endif
  endif

  " call the model and pass the callback
  let l:curlcommand = copy(s:curlcommand)
  if exists("g:llvim_api_key")
    call extend(l:curlcommand, ['--header', 'x-api-key: ' .. g:llvim_api_key])
    call extend(l:curlcommand, ['--header', 'anthropic-version: 2023-06-01'])
  endif

  let l:curlcommand[2] = json_encode(l:querydata)
  let b:job = job_start(l:curlcommand, {"callback": function("s:callbackHandler", [l:cbuffer])})
endfunction

func! llvim#K(...)
  let l:prompt = join(a:000, ' ')
  let l:system_prompt = "You are a helpful assistant in the vim text editor with the ability to control the editor with commands passed to vim's :execute function. Translate the user's natural language command into a command that can be passed to :execute."
  let s:echo_content = v:true
  call llvim#callModel(l:system_prompt, l:prompt, [bufname("%")], s:tools)
endfunc

function! llvim#callModel(system_prompt, user_prompt, context_files, tools)
  let s:tool_calls = []
  let l:cbuffer = bufnr("%")
  " Build the messages array
  let messages = [
        \ {'role': 'system', 'content': a:system_prompt},
        \ {'role': 'user', 'content': a:user_prompt}
        \]

  " Add context from files with line numbers
  for file in a:context_files
    if filereadable(file)
      let file_content = readfile(file)
      " Add line numbers to file content
      let numbered_content = ""
      let line_number = 1
      for line in file_content
        let numbered_content .= printf("%4d: %s\n", line_number, line)
        let line_number += 1
      endfor
      call add(messages, {'role': 'user', 'content': "Context from " . file . ":\n" . numbered_content})
    else
      echo "Warning: File not readable: " . file
    endif
  endfor

  " Build the query data with tools
  let l:querydata = copy(s:querydata)
  let l:querydata.tools = a:tools
  let l:querydata.tool_choice = "required"
  let l:querydata.messages = messages

  echom messages

  " call the model and pass the callback
  let l:curlcommand = copy(s:curlcommand)
  let l:curlcommand[2] = json_encode(l:querydata)
  let b:job = job_start(l:curlcommand, {"callback": function("s:callbackHandler", [l:cbuffer])})
endfunction

" experimental below
"
function! llvim#ReplaceLinesInBuffer(buffer_name, start, end, lines)
    " Get the buffer number from name
    let bufnr = bufnr(a:buffer_name)

    " Check if buffer exists
    if bufnr < 0
        throw 'Buffer not found: ' . a:buffer_name
    endif

    " Switch to the buffer
    execute 'buffer' bufnr

    " Validate line range
    let line_count = line('$')
    if a:start < 1 || a:end > line_count || a:start > a:end
        throw 'Invalid line range: ' . a:start . '-' . a:end
    endif

    " Replace the lines
    call setline(a:start, a:lines[0])
    if a:start + 1 < a:end
      execute (a:start + 1) . ',' . a:end . 'delete'
    endif
    call append(a:start, a:lines[1:-1])
endfunction

function! ExecuteVimCommand(command)
    " List of dangerous commands to disallow
    let disallowed_commands = [
        \ 'shell',
        \ 'system',
        \ 'eval',
        \ 'execute',
        \ 'readfile',
        \ 'writefile',
        \ 'delete',
        \ 'rename',
        \ 'glob',
        \ 'globpath',
        \ 'jobstart',
        \ 'jobsend',
        \ 'jobstop',
        \ 'jobkill',
        \ 'jobwait',
        \ 'jobpid',
        \ 'jobattr',
        \ 'jobstatus',
        \ 'jobset',
        \ 'jobget',
        \ 'jobrun',
        \ ':!']

    " Normalize the command (trim whitespace)
    let normalized_command = substitute(a:command, '^\s\+', '', '')
    let normalized_command = substitute(normalized_command, '\s\+$', '', '')

    " Check if command starts with any disallowed command
    for disallowed in disallowed_commands
        if stridx(normalized_command, disallowed) == 0
            echo "Error: Command '" . a:command . "' is not allowed"
            return
        endif
    endfor

    " Execute the command safely
    execute a:command
endfunction

func llvim#infill()
  let l:endpoint = 'http://127.0.0.1:9000/infill'
  let l:input_prefix = '# todo: implement hello world in go\n'
  let l:input_suffix = '\n'
  let l:input_extra = []
  let l:prompt = 'implement a hello world function in go'
  let l:n_predict = 128
  let l:stop = []
  let l:n_indent = 2
  let l:top_k = 40
  let l:top_p = 0.90
  let l:stream = v:false
  let l:samplers = ["top_k", "top_p", "infill"]
  let l:cache_prompt = v:true
  let l:t_max_prompt_ms = 5000
  let l:t_max_predict_ms = 5000

  " Define the request body with proper variable names
  let l:request = json_encode({
        \ 'input_prefix':     l:input_prefix,
        \ 'input_suffix':     l:input_suffix,
        \ 'input_extra':      l:input_extra,
        \ 'prompt':           l:prompt,
        \ 'n_predict':        l:n_predict,
        \ 'stop':             l:stop,
        \ 'n_indent':         l:n_indent,
        \ 'top_k':            l:top_k,
        \ 'top_p':            l:top_p,
        \ 'stream':           l:stream,
        \ 'samplers':         l:samplers,
        \ 'cache_prompt':     l:cache_prompt,
        \ 't_max_prompt_ms':  l:t_max_prompt_ms,
        \ 't_max_predict_ms': l:t_max_predict_ms,
        \ 'response_fields':  [
        \                       "content",
        \                       "timings/prompt_n",
        \                       "timings/prompt_ms",
        \                       "timings/prompt_per_token_ms",
        \                       "timings/prompt_per_second",
        \                       "timings/predicted_n",
        \                       "timings/predicted_ms",
        \                       "timings/predicted_per_token_ms",
        \                       "timings/predicted_per_second",
        \                       "truncated",
        \                       "tokens_cached",
        \                     ],
        \ })

  " Create temporary file
  "let l:temp_file = tempname()
  let l:temp_file = "/tmp/llvim-request"
  call writefile([l:request], l:temp_file)

  " Build curl command
  let l:curl_command = [
        \ "curl",
        \ "--silent",
        \ "--no-buffer",
        \ "--request", "POST",
        \ "--url", l:endpoint,
        \ "--header", "Content-Type: application/json",
        \ "-d", "@" . l:temp_file,
        \ ]
  echo l:curl_command

  " Execute synchronously
  let l:output = system(join(l:curl_command, ' '))
  echo l:output

  " Clean up temporary file
  "call delete(l:temp_file)

  " Handle errors
  if v:shell_error
    echo "Error: " . l:output
    return ""
  endif

  " Return the result
  return l:output
endfunc

function! GetContextLines(n)
    " Get the current line number
    let current_line = line('.')

    " Get n lines before the cursor
    let lines_before = []
    let start_line = max([1, current_line - a:n])
    let end_line = current_line - 1
    if start_line <= end_line
        let lines_before = getline(start_line, end_line)
    endif

    " Get the line at the cursor
    let current_line_content = getline(current_line)

    " Get n lines after the cursor
    let lines_after = []
    let start_line = current_line + 1
    let end_line = current_line + a:n
    if start_line <= end_line
        let lines_after = getline(start_line, end_line)
    endif

    " Set the results in separate variables
    let g:lines_before = lines_before
    let g:current_line = current_line_content
    let g:lines_after = lines_after

    " Optional: return the variables for immediate use
    return [lines_before, current_line_content, lines_after]
endfunction

" A function to call the diffupdate command and refresh the diff display
function! llvim#DiffCurrentFile()
    " Store the current buffer number
    let original_bufnr = bufnr('%')
    let original_win = bufwinnr(original_bufnr)

    " Get the current file path
    let current_file = expand('%')

    " Check if we have a current file
    if current_file == ''
        echo "No current file open"
        return
    endif

    " Get the file extension
    let file_ext = fnamemodify(current_file, ':e')

    " Generate a temporary file path with same extension
    let temp_file = tempname() . '.' . file_ext

    " Copy current file to temp file
    execute 'silent! write ' . temp_file

    " Split the window vertically
    split

    " Switch back to the original window
    wincmd w

    " Set up diff mode
    set diffopt=vertical,filler,context:2

    " Start diff mode
    execute 'diffsplit ' . temp_file

    " Automatically reload files changed on disk
    set autoread

    " update the diff as we type
    autocmd TextChanged * execute 'diffupdate'

    " jump back to original window
    execute original_win . 'wincmd w'
endfunction
