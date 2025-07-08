# LLVIM
LLM Plugin for VIM because I'm old but want to try new things, using llama.cpp and some ugly vimscript.
(Heavily copied from an old example provided in the llama.cpp repo).

## Setup
1. Install, build [llama.cpp](https://github.com/ggerganov/llama.cpp?tab=readme-ov-file#building-the-project), and run your favorite model (deepseek-coder is pretty cool).
2. Copy the llvim.vim file from this repo to `~/.vim/autoload/`
3. Copy the keybindings and variable below into your `~/.vimrc`
```vim
" llama
let g:llama_api_url= "127.0.0.1:8080/completion"
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
First, you must have a running llama server. It can be local or remote, just set an accurate url in the `g:llama_api_url` var in your `~/.vimrc`.

The plugin operates by calling the llama server with the context you provide via a prompt buffer and any open files (depending on what mode you are in).

### When Editing a File
`CTRL-B` opens the prompt buffer, which writes a file to `/tmp/llama-prompt`.

`CTRL-K`:
- in `insert` mode, will send the current line and default register (last thing yanked) to be rewritten. Great for Deleting a block of code and giving instructions to rewrite or extend.
- in `visual` mode, will copy the selected lines to the context buffer and open it.
- in `normal` mode, will copy the default buffer (last thing yanked) to the context buffer and open in.

### The Context Buffer
`CTRL-B` closes the prompt buffer.
`CTRL-K`:
- in `insert` mode, will send the buffer up to and including the current line for generation.
- in `visual` mode, will send just the selected text for generation.
- in `normal` mode, will send the entire context buffer and all open files for generation. 
