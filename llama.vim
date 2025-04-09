" Requires an already running llama.cpp server
" To install either copy or symlink to ~/.vim/autoload/llama.vim
" Then start with either :call llama#doLlamaGen(),

" or add a keybind to your vimrc such as
" nnoremap Z :call llama#doLlamaGen()<CR>
" Similarly, you could add an insert mode keybind with
" inoremap <C-B> <Cmd>call llama#doLlamaGen()<CR>
"
" g:llama_api_url, g:llama_api_key and g:llama_overrides can be configured in your .vimrc
" let g:llama_api_url = "192.168.1.10:8080"
" llama_overrides can also be set through buffer/window scopes. For instance
" autocmd filetype python let b:llama_overrides = {"temp": 0.2}
" Could be added to your .vimrc to automatically set a lower temperature when
" editing a python script
" Additionally, an override dict can be stored at the top of a file
" !*{"stop": ["User:"]}
" Could be added to the start of your chatlog.txt to set the stopping token
" These parameter dicts are merged together from lowest to highest priority:
" server default -> g:llama_overrides -> w:llama_overrides ->
" b:llama_overrides -> in file (!*) overrides
"
" Sublists (like logit_bias and stop) are overridden, not merged
" Example override:
" !*{"logit_bias": [[13, -5], [2, false]], "temperature": 1, "top_k": 5, "top_p": 0.5, "n_predict": 256, "repeat_last_n": 256, "repeat_penalty": 1.17647}
if !exists("g:llama_api_url")
    let g:llama_api_url= "127.0.0.1:8080"
endif
if !exists("g:llama_overrides")
   let g:llama_overrides = {}
endif
"const s:querydata = {"n_predict": 256, "stop": [ "\n" ], "stream": v:true }
const s:querydata = {"n_predict": -1, "stream": v:true }
const s:curlcommand = ['curl','--data-raw', "{\"prompt\":\"### System:\"}", '--silent', '--no-buffer', '--request', 'POST', '--url', g:llama_api_url .. '/completion', '--header', "Content-Type: application/json"]
let s:linedict = {}

function llama#openOrClosePromptBuffer()
  let bufnr = bufnr("/tmp/llama-prompt")
  if bufname("%") == "/tmp/llama-prompt"
    execute "w|hide"
  else
    " Check if the buffer is already open and switch to it
    if bufnr != -1
      execute "bdelete " . bufnr
    endif
    execute "vnew|e /tmp/llama-prompt"
  endif
endfunction

function llama#extractLastCodeBlock(bufn)
    execute "buffer " . a:bufn
    execute "write"

    " Define the path to the file
    let l:file_path = '/tmp/llama-prompt'

    " Read the file content
    if !filereadable(l:file_path)
        echo "File not found!"
        return
    endif

    let l:lines = readfile(l:file_path)
    if empty(l:lines)
        echo "File is empty!"
        return
    endif

    " Initialize variables
    let l:block_number = 1
    let l:in_block = 0
    let l:code_block = []

    " Loop through each line in the file
    for l:line in l:lines
        " Check for the start of a block
        if l:line =~# '^\s*```'
            if l:in_block
                " End of a block
                let l:in_block = 0
                let l:block = join(l:code_block, "\n")
                call setreg(string(l:block_number), l:block, 'l')
                echo 'Block ' . l:block_number . ' captured in register ' . l:block_number
                let l:block_number += 1
                let l:code_block = []
            else
                " Start of a block
                let l:in_block = 1
            endif
        elseif l:in_block
            " Add line to the current block
            call add(l:code_block, l:line)
        endif
    endfor

    " Capture the last block if any
    if l:in_block
        let l:block = join(l:code_block, "\n")
        call setreg(string(l:block_number), l:block, 'l')
        echo 'Block ' . l:block_number . ' captured in register ' . l:block_number
    endif
endfunction

function! llama#saveHighlightedText()
  let buffer_name = "/tmp/llama-prompt"

  " Get the selected text
  execute 'normal "+Y'
  let stx = &syntax
  let selected_text = getreg('"')

  call llama#openOrClosePromptBuffer()

  " Clear the buffer
  %d

  " Place the text in the default register
  call setreg('"', selected_text, 'l')

  " Split selected_text into lines
  let lines = split(selected_text, '\n')

  " Append each line with proper line breaks and code fence
  call append(line('$'), "```" . stx)
  for line in lines
    call append(line('$'), line)
  endfor
  call append(line('$'), "```")

  echo "Text saved and appended to buffer: " . buffer_name
endfunction

func s:callbackHandler(bufn, channel, msg)
 let l:bufn = a:bufn
 if len(a:msg) < 3
    return
 elseif a:msg[0] == "d"
    let l:msg = a:msg[6:-1]
 else
    let l:msg = a:msg
 endif
 let l:decoded_msg = json_decode(l:msg)
 let l:newtext = split(l:decoded_msg['content'], "\n", 1)
 if len(l:newtext) > 0
    call setbufline(l:bufn, s:linedict[l:bufn], getbufline(l:bufn, s:linedict[l:bufn])[0] .. newtext[0])
 else
    echo "nothing genned"
 endif
 if len(newtext) > 1
    let l:failed = appendbufline(l:bufn, s:linedict[l:bufn], newtext[1:-1])
    let s:linedict[l:bufn] = s:linedict[l:bufn] + len(newtext)-1
 endif
 if has_key(l:decoded_msg, "stop") && l:decoded_msg.stop
     call llama#extractLastCodeBlock(a:bufn)
     echo "Finished generation"
 endif
endfunction


func llama#doLlamaGen()
   if exists("b:job")
      if job_status(b:job) == "run"
         call job_stop(b:job)
         return
      endif
   endif

   let current_mode = mode()
   if bufname("%") != "/tmp/llama-prompt"
     if current_mode ==# 'v' || current_mode ==# 'V' || current_mode ==# "\<C-v>"
       call llama#saveHighlightedText()
     endif
     return
   endif

   if current_mode == "i"
     execute "stopinsert|o|stopinsert"
   endif
   echo "starting generation"

  " load files into context
  call writefile([""], "/tmp/llama-context")
  for buf in filter(getbufinfo({'bufloaded':1}), {v -> len(v:val['windows'])})
    let filename = buf.name
    if !filereadable(filename) || filename == "/tmp/llama-prompt" || filename == "/private/tmp/llama-prompt"
      continue
    endif
    let lines = readfile(filename)
    call writefile([filename, "==========", "\n"], "/tmp/llama-context", "a")
    call writefile(lines, "/tmp/llama-context", "a")
    call writefile(["==========", "\n"], "/tmp/llama-context", "a")
  endfor
  call writefile(["use the files above for context", "always label the language of any code fences/snippets/samples/blocks after the backticks (e.g. ```python)"], "/tmp/llama-context", "a")

   let l:cbuffer = bufnr("%")
   let s:linedict[l:cbuffer] = line('$')
   let l:buflines = getbufline(l:cbuffer, line("."))
   let l:querydata = copy(s:querydata)
   call extend(l:querydata, g:llama_overrides)
   if exists("w:llama_overrides")
      call extend(l:querydata, w:llama_overrides)
   endif
   if exists("b:llama_overrides")
      call extend(l:querydata, b:llama_overrides)
   endif
   if l:buflines[0][0:1] == '!*'
      let l:userdata = json_decode(l:buflines[0][2:-1])
      call extend(l:querydata, l:userdata)
      let l:buflines = l:buflines[1:-1]
   endif

   if mode() == "i"
     let l:querydata.prompt = join(["User:", l:buflines, "\n", "Assistant:"])
     let s:linedict[l:cbuffer] = line('.')
   elseif mode() ==# "n"
     let l:buflines = getbufline(l:cbuffer, 1, 1000)
     let l:querydata.prompt = join(l:buflines, "\n")
     let s:linedict[l:cbuffer] = line('$')
     let context = join(readfile("/tmp/llama-context"))
     let l:querydata.prompt = join(["User:", context, l:querydata.prompt, "Assistant:\n"])
   else
     execute 'normal "aY'
     let l:selectedText = getreg("a")
     if len(split(l:selectedText, "\n")) > 1
       let [l:line_end, l:column_end] = getpos("'>")[1:2]
       let l:querydata.prompt = l:selectedText
       let l:failed = appendbufline(l:cbuffer, l:line_end, '')
       let s:linedict[l:cbuffer] = l:line_end + 1
       call setreg("a", "")
       let l:querydata.prompt = join(["User:", l:querydata.prompt, "Assistant:"])
     else
       let l:querydata.prompt = join(l:buflines, "\n")
       let l:failed = appendbufline(l:cbuffer, line('.'), '')
       let s:linedict[l:cbuffer] = line('.') + 1
       let l:querydata.prompt = join(["User:", l:querydata.prompt, "Assistant:"])
     endif
   endif


   let l:curlcommand = copy(s:curlcommand)
   if exists("g:llama_api_key")
       call extend(l:curlcommand, ['--header', 'Authorization: Bearer ' .. g:llama_api_key])
   endif
   let l:curlcommand[2] = json_encode(l:querydata)
   let b:job = job_start(l:curlcommand, {"callback": function("s:callbackHandler", [l:cbuffer])})
endfunction

" Echos the tokkenization of the provided string , or cursor to end of word
" Onus is placed on the user to include the preceding space
func llama#tokenizeWord(...)
    if (a:0 > 0)
        let l:input = a:1
    else
        exe "normal \"*ye"
        let l:input = @*
    endif
    let l:querydata = {"content": l:input}
    let l:curlcommand = copy(s:curlcommand)
    let l:curlcommand[2] = json_encode(l:querydata)
    let l:curlcommand[8] = g:llama_api_url .. "/tokenize"
   let s:token_job = job_start(l:curlcommand, {"callback": function("s:tokenizeWordCallback", [l:input])})
endfunction

func s:tokenizeWordCallback(plaintext, channel, msg)
    echo '"' .. a:plaintext ..'" - ' .. string(json_decode(a:msg).tokens)
endfunction


" Echos the token count of the entire buffer (or provided string)
" Example usage :echo llama#tokenCount()
func llama#tokenCount(...)
    if (a:0 > 0)
        let l:buflines = a:1
    else
        let l:buflines = getline(1,1000)
        if l:buflines[0][0:1] == '!*'
            let l:buflines = l:buflines[1:-1]
        endif
        let l:buflines = join(l:buflines, "\n")
    endif
    let l:querydata = {"content": l:buflines}
    let l:curlcommand = copy(s:curlcommand)
    let l:curlcommand[2] = json_encode(l:querydata)
    let l:curlcommand[8] = g:llama_api_url .. "/tokenize"
   let s:token_job = job_start(l:curlcommand, {"callback": "s:tokenCountCallback"})
endfunction

func s:tokenCountCallback(channel, msg)
    let resp = json_decode(a:msg)
    echo len(resp.tokens)
endfunction

