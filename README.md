# LLVIM
LLM Plugin for VIM because I'm old but want to try new things, using llama.cpp and some ugly vimscript.

## Setup
1. Install and build [llama.cpp](https://github.com/ggerganov/llama.cpp?tab=readme-ov-file#building-the-project).
2. Copy the llvim.vim file from this repo to `~/.vim/autoload/`
3. Copy the keybindings below into your `~/.vimrc`
```vim
" llama
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
