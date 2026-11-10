" VimTeX - LaTeX plugin for Vim
"
" Maintainer: Karl Yngve Lervåg
" Email:      karl.yngve@gmail.com
"
"
" AI generated change.
let s:texpresso_output = {}
function! vimtex#compiler#texpresso#init(options) abort " {{{1
  return s:compiler.new(a:options)
endfunction

" }}}1

let s:compiler = vimtex#compiler#_template#new({
      \ 'name' : 'texpresso',
      \ 'continuous': 1,
      \ 'stdin_pipe': 1,
      \ 'options' : [],
      \})

function! s:texpresso_find_math_opener(path, lnum) abort
  let l:lines = readfile(a:path)
  let l:end = min([a:lnum, len(l:lines)])
  let l:start = l:end

  " Limit the search to the current paragraph.
  while l:start > 1 && !empty(trim(l:lines[l:start - 2]))
    let l:start -= 1
  endwhile

  let l:stack = []
  let l:delimiters = [
        \ ['\(', '\)'],
        \ ['\[', '\]'],
        \ ['$$', '$$'],
        \ ['$', '$'],
        \]

  " Scan the paragraph from its beginning to the reported location.
  for l:i in range(l:start, l:end)
    let l:text = l:lines[l:i - 1]

    " Remove comments, respecting escaped percent signs.
    let l:text = substitute(l:text, '\%(^\|[^\\]\)\zs%.*$', '', '')

    let l:pos = 0
    while l:pos < strlen(l:text)
      let l:found = {}
      for l:delimiter in l:delimiters
        let l:open = l:delimiter[0]
        let l:close = l:delimiter[1]
        let l:pattern = l:open ==# '$'
              \ ? '\$\%(\$\)\@!'
              \ : escape(l:open, '\')

        let l:match = matchstrpos(l:text, l:pattern, l:pos)
        if l:match[1] >= 0
          if empty(l:found) || l:match[1] < l:found.pos
            let l:found = {
                  \ 'pos': l:match[1],
                  \ 'open': l:open,
                  \ 'close': l:close,
                  \}
          endif
        endif
      endfor

      if empty(l:found)
        break
      endif

      let l:pos = l:found.pos + strlen(l:found.open)

      if l:found.open ==# '$'
        if !empty(l:stack) && l:stack[-1].open ==# '$'
          call remove(l:stack, -1)
        else
          call add(l:stack, {
                \ 'line': l:i,
                \ 'col': l:found.pos + 1,
                \ 'open': '$',
                \})
        endif
      else
        call add(l:stack, {
              \ 'line': l:i,
              \ 'col': l:found.pos + 1,
              \ 'open': l:found.open,
              \ 'close': l:found.close,
              \})
      endif
    endwhile
  endfor

  " Return the most recent unmatched opener.
  return empty(l:stack) ? {} : l:stack[-1]
endfunction
function! s:compiler.__check_requirements() abort dict " {{{1
  if !executable('texpresso')
    call vimtex#log#warning('texpresso is not executable!')
    let self.enabled = v:false
  endif
endfunction
" }}}1

function! s:compiler.__init() abort dict " {{{1
  let self.start = function('s:compiler_start', [self.start])
  let self.stop = function('s:compiler_stop', [self.stop])
  call add(self.hooks,
        \ function('s:texpresso_process_message', [self.file_info.target]))
endfunction
" }}}1

function! s:compiler.__build_cmd(passed_options) abort dict " {{{1
  let l:options = ['-json', '-lines'] + self.options
  return 'texpresso ' . join(l:options)
        \ . (empty(a:passed_options) ? '' : ' ' . trim(a:passed_options))
        \ . ' ' . vimtex#util#shellescape(self.file_info.target_basename)
endfunction
" }}}1

function! s:compiler_start(super, ...) abort dict " {{{1
  let s:texpresso_output[self.file_info.target] = []
  call call(a:super, a:000, self)

  augroup vimtex_compiler_texpresso
    autocmd! * <buffer>
    autocmd CursorMoved <buffer> call b:vimtex.compiler.texpresso_synctex_forward()
    autocmd ColorScheme <buffer> call b:vimtex.compiler.texpresso_theme()
  augroup END

  if has('nvim')
    let self.nvim_detach = luaeval(
          \ "require('vimtex.compiler.texpresso').attach()")
  else
    let self.listener_id = listener_add(function(self.texpresso_listener, [], self))
  endif

  call self.texpresso_theme()
  call self.texpresso_reload()
endfunction
" }}}1

function! s:compiler_stop(super, ...) abort dict " {{{1
  call call(a:super, a:000, self)

  if has('nvim') && has_key(self, 'nvim_detach')
    call self.nvim_detach()
    unlet self.nvim_detach
  elseif has_key(self, 'listener_id')
    call listener_remove(self.listener_id)
    unlet self.listener_id
  endif

  autocmd! vimtex_compiler_texpresso * <buffer>
endfunction
" }}}1

function! s:compiler.texpresso_listener(bufnr, start, end, added, changes) abort dict " {{{1
  let l:path = fnamemodify(bufname(a:bufnr), ":p")
  let l:lines = getbufline(a:bufnr, a:start, a:end - 1 + a:added)
  call self.texpresso_send("change-lines", l:path, a:start - 1, a:end - a:start,  s:join_lines(l:lines))
endfunction
" }}}1

function! s:compiler.texpresso_theme() abort dict " {{{1
  let l:normal_id = synIDtrans(hlID('Normal'))
  let l:fg = synIDattr(l:normal_id, 'fg#')
  let l:bg = synIDattr(l:normal_id, 'bg#')

  if l:fg ==# '' || l:bg ==# ''
    return
  endif

  call self.texpresso_send("theme", s:convert_color(l:bg), s:convert_color(l:fg))
endfunction
" }}}1

function! s:compiler.texpresso_reload() abort dict " {{{1
  let l:path = fnamemodify(bufname(), ":p")
  call self.texpresso_send("open", l:path, s:join_lines(getline(1, '$')))
endfunction
" }}}1

function! s:compiler.texpresso_synctex_forward() abort dict "{{{1
  let l:path = fnamemodify(bufname(), ":p")
  let l:lnum = getpos('.')[1]
  let l:prev_key = 'texpresso_synctex_forward_previous'
  if has_key(self, l:prev_key) && self[l:prev_key] == [l:path, l:lnum]
    return
  endif
  let self.texpresso_synctex_forward_previous = [l:path, l:lnum]
  call self.texpresso_send("synctex-forward", l:path, l:lnum)
endfunction
" }}}1

function! s:compiler.texpresso_previous_page() abort dict "{{{1
  call self.texpresso_send("previous-page")
endfunction
"}}}1

function! s:compiler.texpresso_next_page() abort dict "{{{1
  call self.texpresso_send("next-page")
endfunction
"}}}1

function! s:compiler.texpresso_send(...) abort dict " {{{1
  if !self.is_running() | return | endif
  try
    if has('nvim')
      call chansend(self.job, json_encode(a:000) .. "\n")
    else
      call ch_sendraw(self.job, json_encode(a:000) .. "\n")
    endif
  catch
    " chansend/ch_sendraw can fail transiently before TeXpresso has finished
    " opening its stdin pipe. Propagating the exception causes Neovim to close
    " the channel, which delivers EOF to TeXpresso and terminates it.
    call vimtex#log#info(
          \ 'TeXpresso: dropped message (process still starting): '
          \ . v:exception
          \)
  endtry
endfunction
" }}}1

" Changed!
function! s:texpresso_process_message(path, json) abort
  for l:json in split(a:json, "\n")
    if !empty(l:json)
      call s:texpresso_process_message_line(a:path, l:json)
    endif
  endfor
endfunction

function! s:texpresso_process_message_line(path, json) abort
  try
    let l:msg = json_decode(a:json)
  catch
    return
  endtry

  if type(l:msg) != v:t_list || empty(l:msg)
    return
  endif

  if l:msg[0] ==# 'synctex'
    call vimtex#view#inverse_search(l:msg[2], l:msg[1])

  elseif l:msg[0] ==# 'truncate-lines'
    if l:msg[1] ==# 'out'
      let l:raw = get(s:texpresso_output, a:path, [])
      let s:texpresso_output[a:path] = slice(l:raw, 0, l:msg[2])
      call s:texpresso_update_quickfix(a:path)
    endif

  elseif l:msg[0] ==# 'append-lines'
    if l:msg[1] ==# 'out'
      let l:raw = get(s:texpresso_output, a:path, [])
      call extend(l:raw, split(join(l:msg[2:], ''), "\n", 1))
      let s:texpresso_output[a:path] = l:raw
      call s:texpresso_update_quickfix(a:path)
    endif
  endif
endfunction

function! s:texpresso_update_quickfix(path) abort
  let l:items = []
  let l:pending = {}

  for l:line in get(s:texpresso_output, a:path, [])
    let l:line = substitute(l:line, '\r$', '', '')

    " Errors start with ! and give their source line afterwards.
    let l:error = matchlist(l:line, '^\s*!\s*\(.*\)$')
    if !empty(l:error)
      let l:pending = {
            \ 'text': l:error[1],
            \ 'type': 'E',
            \}
      continue
    endif

    " Warnings include their source line directly.
    let l:warning = matchlist(
          \ l:line,
          \ '^\s*LaTeX Warning:\s*\(.\{-}\)\s\+on input line \(\d\+\)\.\s*$'
          \)
    if !empty(l:warning)
      call add(l:items, {
            \ 'filename': a:path,
            \ 'lnum': str2nr(l:warning[2]),
            \ 'type': 'W',
            \ 'text': l:warning[1],
            \})
      continue
    endif

    " Errors use the form: l.123 <source text>
    let l:source = matchlist(l:line, '^\s*l\.\(\d\+\)\s*\(.*\)$')
    if !empty(l:source) && !empty(l:pending)
      let l:lnum = str2nr(l:source[1])
      let l:col = 1

      if l:pending.text =~# '^Missing \$ inserted'
        let l:opener = s:texpresso_find_math_opener(a:path, l:lnum)
        if !empty(l:opener)
          let l:lnum = l:opener.line
          let l:col = l:opener.col
        endif
      endif

      call add(l:items, {
            \ 'filename': a:path,
            \ 'lnum': l:lnum,
            \ 'col': l:col,
            \ 'type': l:pending.type,
            \ 'text': l:pending.text,
            \})
      let l:pending = {}
    endif
  endfor

  " Replace the previous TeXpresso diagnostics. This also removes
  " errors that disappeared after an edit.
  call setqflist([], 'r', {
        \ 'title': 'TeXpresso diagnostics',
        \ 'items': l:items,
        \})

  " Respect VimTeX's Quickfix window settings.
  if get(g:, 'vimtex_quickfix_mode', 0) > 0
    let l:errors = filter(copy(l:items), 'v:val.type ==# "E"')
    let l:warnings = filter(copy(l:items), 'v:val.type ==# "W"')
    let l:should_open = !empty(l:errors)
          \ || (!empty(l:warnings)
          \ && get(g:, 'vimtex_quickfix_open_on_warning', 0))

    if l:should_open
      let l:winid = win_getid()
      botright cwindow
      if g:vimtex_quickfix_mode == 2
        call win_gotoid(l:winid)
      endif
    else
      cclose
    endif
  endif
endfunction

" }}}1

function s:join_lines(lines) abort " {{{1
  return a:lines == [] ? '' : join(a:lines, "\n") .. "\n"
endfunction

" }}}1

function s:convert_color(color) abort " {{{1
  if a:color =~# '^#'
    let l:hex = a:color
  else
    let l:hex = s:cterm_to_hex(str2nr(a:color))
  endif
  return [str2nr(l:hex[1:2], 16) / 255.0,
        \ str2nr(l:hex[3:4], 16) / 255.0,
        \ str2nr(l:hex[5:6], 16) / 255.0]
endfunction

" }}}1

function s:cterm_to_hex(n) abort " {{{1
  if a:n < 16
    let l:system = [
          \ '#000000', '#800000', '#008000', '#808000',
          \ '#000080', '#800080', '#008080', '#c0c0c0',
          \ '#808080', '#ff0000', '#00ff00', '#ffff00',
          \ '#0000ff', '#ff00ff', '#00ffff', '#ffffff']
    return l:system[a:n]
  elseif a:n < 232
    let l:i = a:n - 16
    let l:levels = [0, 95, 135, 175, 215, 255]
    let l:r = l:levels[l:i / 36]
    let l:g = l:levels[(l:i / 6) % 6]
    let l:b = l:levels[l:i % 6]
    return printf('#%02x%02x%02x', l:r, l:g, l:b)
  else
    let l:v = 8 + (a:n - 232) * 10
    return printf('#%02x%02x%02x', l:v, l:v, l:v)
  endif
endfunction

" }}}1
