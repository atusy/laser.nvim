" pum#open resets insertion state and fires close/open events. This adapter's
" small in-place update is isolated here because pum has no public list update.
" Formatting, dimensions and the visible prefix stay unchanged while browsing.
function laser#pum#update(items, lines, frozen) abort
  let pum = pum#_get()
  let old_len = pum.len
  let pum.items = pum.reversed ? reverse(copy(a:items)) : copy(a:items)
  let pum.len = len(pum.items)
  if pum.horizontal_menu
    call pum#popup#_redraw_horizontal_menu()
    return
  endif

  let lines = pum.reversed ? reverse(copy(a:lines)) : a:lines
  if pum.reversed
    let tail = pum.len - a:frozen
    call nvim_buf_set_lines(pum.buf, 0, old_len - a:frozen, v:true,
          \ tail > 0 ? lines[: tail - 1] : [])
    if pum.cursor > 0
      let pum.cursor += pum.len - old_len
    endif
  else
    call nvim_buf_set_lines(pum.buf, a:frozen, -1, v:true, lines[a:frozen :])
  endif
endfunction

function laser#pum#scrollbar() abort
  let pum = pum#_get()
  let options = pum#_options()
  if pum.horizontal_menu || options.scrollbar_char ==# '' || pum.len <= pum.height
    return
  endif
  call nvim_buf_set_lines(pum.scroll_buf, 0, -1, v:true,
        \ repeat([options.scrollbar_char], pum.len))
  let pum.scroll_height = max([1, float2nr(floor(
        \ pum.height * (pum.height + 0.0) / pum.len + 0.5))])
  let offset = min([pum.height - 1, float2nr(floor(
        \ pum.height * (line('w0', pum.id) + 0.0) / pum.len + 0.5))])
  let config = #{relative: 'editor', border: 'none',
        \ row: pum.scroll_row + offset, col: pum.scroll_col,
        \ width: strdisplaywidth(options.scrollbar_char), height: pum.scroll_height,
        \ style: 'minimal', zindex: options.zindex + 1}
  if pum.scroll_id > 0
    call nvim_win_set_config(pum.scroll_id, config)
  else
    let config.noautocmd = v:true
    let pum.scroll_id = nvim_open_win(pum.scroll_buf, v:false, config)
    call nvim_set_option_value('winhighlight', 'Normal:PmenuSbar', #{win: pum.scroll_id})
    call nvim_set_option_value('winblend', options.blend, #{win: pum.scroll_id})
  endif
endfunction

" Update only the still-selected candidate; Lua receives copies of Vim lists.
function laser#pum#preview(data, info, filetype) abort
  let pum = pum#_get()
  if !pum#visible() || !pum.preview || pum.cursor <= 0
    return
  endif
  let item = pum.items[pum.cursor - 1]
  if get(get(item, 'user_data', {}), 'laser', {}) != a:data
    return
  endif
  let item.info = a:info
  let item.user_data.laser_preview_filetype = a:filetype
  call pum#open_preview()
endfunction
