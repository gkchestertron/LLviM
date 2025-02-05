# LLVIM
LLM Plugin for VIM because I'm old but want to try new things, using llama.cpp and some ugly vimscript.

## Setup
1. Install and build [llama.cpp](https://github.com/ggerganov/llama.cpp?tab=readme-ov-file#building-the-project).
2. Copy the llvim.vim file from this repo to `~/.vim/autoload/`
3. Copy the keybindings below into your `~/.vimrc`
```vim
" llama
let g:llama_api_url= "127.0.0.1:9000"
autocmd BufWinEnter /tmp/llama-prompt set syntax=markdown
" insert mode
inoremap <C-K> <Cmd>call llama#doLlamaGen()<CR>
" normal mode
nnoremap <C-K> <Cmd>call llama#doLlamaGen()<CR>
nnoremap <C-B> <Cmd>call llama#openOrClosePromptBuffer()<CR>
"visual mode
vnoremap <C-K> <Cmd>call llama#doLlamaGen()<CR>
```

## Usage
First, you must have a running llama server. It can be local or remote, just set an accurate url in the `g:llama_api_url` var in your `~/.vimrc`. I run mine locally on port 9000 (because the default of 8080 conflicts with my network manager.

The plugin operates by calling the llama server with the context you provide via a prompt buffer and any open files (depending on what mode you are in).

### When Editing a File
`CTRL-B` opens the prompt buffer, which writes a file to `/tmp/llama-prompt`.
`CTRL-K` will do nothing, unless you are in visual mode. In visual mode it will copy the selected text into the prompt buffer.


### The Prompt Buffer
`CTRL-B` opens the prompt buffer, which writes a file to `/tmp/llama-prompt`.
`CTRL-K` sends the context/prompt to the server, appends the returned completion to the buffer, and copies each block inside a code fence ("```language...```") to a numbered buffer. The first code-fenced block will also be copied to the default buffer so you can easily paste it into another file.

#### Context
What context is sent depends on what mode you are in:
- `normal mode` will send all open files and the whole prompt buffer.
- `insert mode` will send only the current line - great for asking simple questions without having to wait for the model to process a large context.
- `visual mode` will send only the selected text as context.
In all cases, additional instructions are appended to encase all code in fences for syntax highlighting and easy copying.
