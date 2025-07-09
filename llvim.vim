" get setting overrides
if !exists("g:llvim_api_url")
    let g:llvim_api_url= "127.0.0.1:8080/completion"
endif
if !exists("g:llvim_overrides")
   let g:llvim_overrides = {}
endif
const s:querydata = {"n_predict": -1, "stream": v:true }
const s:curlcommand = ['curl','--data-raw', "{\"prompt\":\"### System: You are a helpful coding assistant.\"}", '--silent', '--no-buffer', '--request', 'POST', '--url', g:llvim_api_url, '--header', "Content-Type: application/json"]
let s:linedict = {}

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
      execute "b" . l:bufn

    " already open, don't make more of them
    else
      return
    endif

  " no buffer, let's make one
  else
    execute "vnew|e /tmp/llvim-prompt"
  endif
endfunction

" put last given code block in default register
function llvim#extractLastCodeBlock(bufn)
  " Define the path to the file
  let l:file_path = '/tmp/llvim-prompt'

  " Read the file content
  if !filereadable(l:file_path)
      echo "File not found!"
      return
  endif

  " file empty, do nothing
  let l:lines = readfile(l:file_path)
  if empty(l:lines)
      echo "File is empty!"
      return
  endif

  " Initialize variables
  let l:block_number = 1
  let l:in_block = 0
  let l:code_block = []

  " Loop through each line in the file and capture the code blocks
  for l:line in l:lines
    " Check for the start or end of a block
    if l:line =~# '^\s*```'

      " at the end of a block - join all the lines and put in a register
      if l:in_block
        let l:in_block = 0
        let l:block = join(l:code_block, "\n")
        call setreg(string(l:block_number), l:block, 'l')
        call setreg('"', l:block, 'l')
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
      let l:block = join(l:code_block, "\n")
      call setreg(string(l:block_number), l:block, 'l')
      call setreg('"', l:block, 'l')
  endif
endfunction

" save selected lines for context - only called from file, not context buffer
function! llvim#saveHighlightedText()
  " get syntax and selected text
  let stx = &syntax
  let selected_text = getreg('"')

  " Split selected_text into lines
  let lines = split(selected_text, '\n')

  " open and clear the buffer
  call llvim#openOrClosePromptBuffer()
  execute '%d'

  " Append each line with proper line breaks and code fence
  call append(line('$'), "```" . stx)
  for line in lines
    call append(line('$'), line)
  endfor
  call append(line('$'), "```")
endfunction

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

  " skip empty messages
  if len(a:msg) < 3
    return

  " skip 'data: ' at the beginning of the message to unnest data
  elseif a:msg[0] == "d"
    echo a:msg
    let l:msg = a:msg[6:-1]
    
  " message is not nested
  else
    let l:msg = a:msg
  endif

  " decode message and split into lines
  let l:decoded_msg = json_decode(l:msg)
  let l:newtext = split(l:decoded_msg['content'], "\n", 1)

  " append the first line of message to the starting line in the file or buffer
  if len(l:newtext) > 0
    call setbufline(l:bufn, s:linedict[l:bufn], getbufline(l:bufn, s:linedict[l:bufn])[0] .. newtext[0])
  else
    echo "nothing genned"
  endif

  " Append subsequent lines to the file or buffer after the starting line
  " and update the line pointer for the next line
  if len(l:newtext) > 1
    for l:line in newtext[1:-1]
      let l:result = appendbufline(l:bufn, s:linedict[l:bufn], l:line)
    endfor
    let s:linedict[l:bufn] = s:linedict[l:bufn] + len(newtext)-1
  endif

  " done
  if has_key(l:decoded_msg, "stop") && l:decoded_msg.stop
    call llvim#extractLastCodeBlock(a:bufn)
    echo "Finished generation"
  endif
endfunction

" build context based on, uh... context and send to model for generation
func llvim#doLlamaGen()
  " stop running completion task if it exists
  if exists("b:job")
    if job_status(b:job) == "run"
      call job_stop(b:job)
      return
    endif
  endif

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
      let l:baseprompt = "Rewrite and return the " . stx . " code sample above according to the instructions below."
      let l:postprompt = "Do not explain outside of inline comments. Add the same number of spaces at the beginning of each line as in the sample to match indentation. Do not return in code blocks. Return just the raw code as if you are typing it into a text editor."
      let l:querydata.prompt = join(["User:", l:selectedText, l:baseprompt, l:buflines, l:postprompt, "Assistant:"], "\n")

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

      " set the prompt string
      let l:querydata.prompt = join(["User:", l:buflines, "Assistant:"], "\n")
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
      let l:baseprompt = "Rewrite and return the " . stx . " code sample above according to the instructions below."
      let l:postprompt = "Do not explain outside of inline comments. Add the same number of spaces at the beginning of each line as in the sample to match indentation. Do not return in code blocks. Return just the raw code as if you are typing it into a text editor."
      let l:querydata.prompt = join(["User:", context, l:selectedText, l:baseprompt, l:buflines, l:postprompt, "Assistant:"], "\n")

    " in context buffer - send whole buffer and all open files
    else
      echo "sending all files and buffer for generation"
      sleep 500m

      " build and set the context for generation
      let context = join(readfile("/tmp/llvim-context"), "\n")
      let l:buflines = getbufline(l:cbuffer, 1, '$')
      let l:baseprompt = "Always label the language of any code fences/snippets/samples/blocks after the backticks (e.g. ```python). Return only the line, lines or function asked for in the code block. Concisely comment your code."
      let l:querydata.prompt = join(["User:", context, l:baseprompt, join(l:buflines, "\n"), "Assistant:\n"])

      " Store the line number for callback
      let s:linedict[l:cbuffer] = line('$') + 1

      " add lines and move cursor so we can watch it stream
      call appendbufline(l:cbuffer, line('$'), ['', '', ''])
      call cursor(line('$'), 0)
    endif

  " visual mode 
  else
    " yank currently selected lines
    execute 'normal "aY'
    let l:selectedText = getreg("a")

    " in file - clear buffer and paste in selected lines
    if bufname("%") != "/tmp/llvim-prompt"
      call llvim#saveHighlightedText()
      let l:cbuffer = bufnr("%")
      let l:failed = appendbufline(l:cbuffer, line('$'), '')
      normal! G$
      startinsert
      return

    " in buffer - just send selection
    else
      echo "sending selection for generation"
      sleep 500m

      " Get the position of the end of the selected text
      " getpos("'>")[1:2] returns the line and column number of the end of the selection
      let [l:line_end, l:column_end] = getpos("'>")[1:2]

      " Append an empty line to the current buffer at the end of the selected text
      let l:failed = appendbufline(l:cbuffer, l:line_end, '')

      " save position for callback
      let s:linedict[l:cbuffer] = l:line_end + 1

      " Join the user prompt and the assistant response into a single string
      let l:querydata.prompt = join(["User:", l:selectedText, "Assistant:\n"])
    endif
  endif

  " call the model and pass the callback
  let l:curlcommand = copy(s:curlcommand)
  if exists("g:llvim_api_key")
    call extend(l:curlcommand, ['--header', 'x-api-key: ' .. g:llvim_api_key])
    call extend(l:curlcommand, ['--header', 'anthropic-version: 2023-06-01'])
  endif
  "echo querydata.prompt
  let l:curlcommand[2] = json_encode(l:querydata)
  let b:job = job_start(l:curlcommand, {"callback": function("s:callbackHandler", [l:cbuffer])})
endfunction
