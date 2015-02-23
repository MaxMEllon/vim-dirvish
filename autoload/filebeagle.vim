""  Copyright 2014 Jeet Sukumaran.
"
" Things that are unnecessary when you set the buffer name:
"
" - let &titlestring = expand(self.focus_dir, 1)
" - specialized 'cd', 'cl'
"
" Things that are unnecessary when you conceal the full file paths:
" - specialized "yank" commands
" - specialized "read" commands (instead: yy and :r ...)



if has("win32")
    let s:sep = '\'
    let s:sep_as_pattern = '\\'
else
    let s:sep = '/'
    let s:sep_as_pattern = '/'
endif

function! s:new_notifier(name)
    let m = {}
    let m["name"] = a:name
    let m["title"] = empty(a:name) ? "dirvish" : "dirvish (" . m["name"] . ")"

    function! m.format(leader, msg) dict
        return self.title . ": " . a:leader.a:msg
    endfunction
    function! m.error(msg) dict
        redraw
        echohl ErrorMsg
        echomsg self.format("", a:msg)
        echohl None
    endfunction
    function! m.warn(msg) dict
        redraw
        echohl WarningMsg
        echomsg self.format("", a:msg)
        echohl None
    endfunction
    function! m.info(msg) dict
        redraw
        echohl None
        echo self.format("", a:msg)
    endfunction

    return m
endfunction

function! s:parent_dir(current_dir)
    let l:current_dir = fnamemodify(a:current_dir, ":p")
    if has("win32")
        let d = join(split(l:current_dir, s:sep_as_pattern)[:-2], s:sep)
        if empty(d)
            let d = a:current_dir
        endif
        if d =~ ":$"
            let d = d . s:sep
        endif
    else
        let d = s:sep . join(split(l:current_dir, s:sep_as_pattern)[:-2], s:sep)
    endif
    return d
endfunction

function! s:base_dirname(dirname)
    let l:dirname = fnamemodify(a:dirname, ":p")
    if l:dirname == s:sep
        return s:sep
    endif
    return split(l:dirname, s:sep_as_pattern)[-1] . s:sep
endfunction

function! s:discover_paths(current_dir, glob_pattern, is_include_hidden)
    if a:is_include_hidden
        let path_str = glob(a:current_dir.s:sep.'.[^.]'.a:glob_pattern, 1)."\n".glob(a:current_dir.s:sep.a:glob_pattern, 1)
    else
        let path_str = glob(a:current_dir.s:sep.a:glob_pattern, 1)
    endif
    let paths = split(path_str, '\n')
    call sort(paths)
    let dir_paths = []
    let file_paths = []

    let parent_path = s:parent_dir(a:current_dir)
    call add(dir_paths, {
                \ "full_path" : a:current_dir . s:sep . '..' . s:sep,
                \ "dirname" : fnamemodify(parent_path, ":h"),
                \ })

    for path_entry in paths
        let path_entry = substitute(path_entry, s:sep_as_pattern.'\+', s:sep, 'g')
        let full_path = fnamemodify(path_entry, ":p")
        let dirname = fnamemodify(path_entry, ":h")
        call add(
            \ isdirectory(path_entry) ? dir_paths : file_paths,
            \ { "full_path": full_path, "dirname" : dirname })
    endfor
    return [dir_paths, file_paths]
endfunction

function! s:sanity_check() abort
    if !isdirectory(bufname('%'))
        echoerr 'dirvish: fatal error: buffer name is not a directory'
    endif
endfunction

function! s:new_dirvish()
    let l:directory_viewer = {}

    " buf_num, int
    "   - The buffer number to use, or -1 to create new
    " focus_dir, string
    "   - The full path to the directory being listed/viewed
    " focus_file, string
    "   - The full path to the file or directory that is should be the initial
    "     target or focus
    " calling_buf_num, int
    "   - The buffer number of the buffer from which FileBeagle was invoked.
    "     If `buf_num` > -1, and `calling_buf_num` == `buf_num`, assume it is
    "     because FileBeagle was invoked as a result of Vim being called upon
    "     to edit a directory.
    " prev_focus_dirs, list of tuples, [ (string, string) ]
    "   - The history stack, with the first element of the tuple being the
    "     directory previously visited and the second element of the tuple being
    "     the last selected entry in that directory
    " default_targets_for_directory, dictionary {string: string}
    "   - Keys are directories and values are the corresponding default target
    "     or selected item when that directory will be visited again.
    " is_filtered, boolean
    "   - If 1, then entries will be filtered following `filter_exp` if
    "     `filter_exp` is not empty; otherwise, entries will not be filtered
    " filter_exp, regular expression pattern string
    "   - Regular expression pattern to be used to filter entries if
    "     `is_filtered` is 1
    " is_include_hidden, boolean
    "   -  If 1, hidden files and directories (paths beginning with '.') will
    "      be listed; otherwise, they will not be shown.
    function! l:directory_viewer.open_dir(
                \ buf_num,
                \ focus_dir,
                \ focus_file,
                \ calling_buf_num,
                \ prev_focus_dirs,
                \ default_targets_for_directory,
                \ is_filtered,
                \ filter_exp,
                \ is_include_hidden,
                \) dict
        let self.focus_dir = fnamemodify(a:focus_file, ":p")

        let self.buf_num = a:buf_num == -1 ? bufnr(self.focus_dir, 1) : a:buf_num

        let self.focus_file = fnamemodify(a:focus_file, ":p:t")
        let self.prev_buf_num = empty(a:calling_buf_num)
                    \ ? bufnr('%') : a:calling_buf_num
        let self.prev_focus_dirs = deepcopy(a:prev_focus_dirs)
        let self.default_targets_for_directory = deepcopy(a:default_targets_for_directory)
        let self.is_include_hidden = a:is_include_hidden

        execute "silent keepalt keepjumps buffer " . self.buf_num

        " buffer context
        let b:dirvish = self
        call self.setup_buffer_opts()
        call self.setup_buffer_syntax()
        call self.setup_buffer_keymaps()

        " filters
        let self.is_filtered = a:is_filtered
        let self.filter_exp = a:filter_exp

        call self.render_buffer()
    endfunction

    function! l:directory_viewer.setup_buffer_opts() dict
        setlocal nobuflisted
        setlocal bufhidden=wipe buftype=nofile noswapfile nowrap nolist cursorline

        if &l:spell
            setlocal nospell
            augroup dirvish_bufferopts
                autocmd!
                autocmd BufLeave <buffer> setlocal nospell | autocmd! dirvish_bufferopts *
            augroup END
        endif

        setlocal undolevels=-1
        set filetype=dirvish
    endfunction

    function! l:directory_viewer.setup_buffer_syntax() dict
        if has("syntax")
            syntax clear
            let self.orig_concealcursor = &l:concealcursor
            let self.orig_conceallevel = &l:conceallevel
            setlocal concealcursor=nc conceallevel=3

            syntax match DirvishPathHead '\v.*\/\ze[^\/]+\/?$' conceal
            syntax match DirvishPathTail '\v[^\/]+\/$'
            highlight! link DirvishPathTail Directory

            augroup dirvish_syntaxteardown
                autocmd!
                autocmd BufLeave <buffer> let &l:concealcursor = b:dirvish.orig_concealcursor
                    \ | let &l:conceallevel = b:dirvish.orig_conceallevel
                    \ | autocmd! dirvish_syntaxteardown *
            augroup END
        endif
    endfunction

    function! l:directory_viewer.setup_buffer_keymaps() dict

        " Avoid 'cannot modify' error for  keys.
        for key in [".", "p", "P", "C", "x", "X", "r", "R", "i", "I", "a", "A", "D", "S", "U"]
            if !hasmapto(key, 'n')
                execute "nnoremap <buffer> " . key . " <NOP>"
            endif
        endfor

        let l:default_normal_plug_map = {}
        let l:default_visual_plug_map = {}

        """ Directory list splitting
        nnoremap <buffer> <silent> <C-W><C-V>    :call b:dirvish.new_viewer("vert sp")<CR>
        nnoremap <buffer> <silent> <C-W>v        :call b:dirvish.new_viewer("vert sp")<CR>
        nnoremap <buffer> <silent> <C-W>V        :call b:dirvish.new_viewer("vert sp")<CR>
        nnoremap <buffer> <silent> <C-W><C-S>    :call b:dirvish.new_viewer("sp")<CR>
        nnoremap <buffer> <silent> <C-W>s        :call b:dirvish.new_viewer("sp")<CR>
        nnoremap <buffer> <silent> <C-W>S        :call b:dirvish.new_viewer("sp")<CR>
        nnoremap <buffer> <silent> <C-W><C-T>    :call b:dirvish.new_viewer("tabedit")<CR>
        nnoremap <buffer> <silent> <C-W>t        :call b:dirvish.new_viewer("tabedit")<CR>
        nnoremap <buffer> <silent> <C-W>T        :call b:dirvish.new_viewer("tabedit")<CR>

        """ Directory list buffer management
        nnoremap <Plug>(FileBeagleBufferRefresh)                            :call b:dirvish.render_buffer()<CR>
        let l:default_normal_plug_map['FileBeagleBufferRefresh'] = 'R'
        nnoremap <Plug>(FileBeagleBufferSetFilter)                          :call b:dirvish.set_filter_exp()<CR>
        let l:default_normal_plug_map['FileBeagleBufferSetFilter'] = 'f'
        nnoremap <Plug>(FileBeagleBufferToggleFilter)                       :call b:dirvish.toggle_filter()<CR>
        let l:default_normal_plug_map['FileBeagleBufferToggleFilter'] = 'F'
        nnoremap <Plug>(FileBeagleBufferToggleHiddenAndIgnored)             :call b:dirvish.toggle_hidden()<CR>
        let l:default_normal_plug_map['FileBeagleBufferToggleHiddenAndIgnored'] = 'gh'
        nnoremap <Plug>(FileBeagleBufferQuit)                               :call b:dirvish.quit_buffer()<CR>
        let l:default_normal_plug_map['FileBeagleBufferQuit'] = 'q'

        """ Open selected file/directory
        nnoremap <Plug>(FileBeagleBufferVisitTarget)                        :<C-U>call b:dirvish.visit_target("edit", 0)<CR>
        let l:default_normal_plug_map['FileBeagleBufferVisitTarget'] = 'o'
        vnoremap <Plug>(FileBeagleBufferVisitTarget)                        :call b:dirvish.visit_target("edit", 0)<CR>
        let l:default_visual_plug_map['FileBeagleBufferVisitTarget'] = 'o'
        nnoremap <Plug>(FileBeagleBufferBgVisitTarget)                      :<C-U>call b:dirvish.visit_target("edit", 1)<CR>
        let l:default_normal_plug_map['FileBeagleBufferBgVisitTarget'] = g:filebeagle_buffer_background_key_map_prefix . 'o'
        vnoremap <Plug>(FileBeagleBufferBgVisitTarget)                      :call b:dirvish.visit_target("edit", 1)<CR>
        let l:default_visual_plug_map['FileBeagleBufferBgVisitTarget'] = g:filebeagle_buffer_background_key_map_prefix . 'o'

        """ Special case: <CR>
        nmap <buffer> <silent> <CR> <Plug>(FileBeagleBufferVisitTarget)
        vmap <buffer> <silent> <CR> <Plug>(FileBeagleBufferVisitTarget)
        execute "nmap <buffer> <silent> " . g:filebeagle_buffer_background_key_map_prefix . "<CR> <Plug>(FileBeagleBufferBgVisitTarget)"
        execute "vmap <buffer> <silent> " . g:filebeagle_buffer_background_key_map_prefix . "<CR> <Plug>(FileBeagleBufferBgVisitTarget)"

        nnoremap <Plug>(FileBeagleBufferSplitVerticalVisitTarget)           :<C-U>call b:dirvish.visit_target("vert sp", 0)<CR>
        let l:default_normal_plug_map['FileBeagleBufferSplitVerticalVisitTarget'] = 'v'
        vnoremap <Plug>(FileBeagleBufferSplitVerticalVisitTarget)           :call b:dirvish.visit_target("vert sp", 0)<CR>
        let l:default_visual_plug_map['FileBeagleBufferSplitVerticalVisitTarget'] = 'v'
        nnoremap <Plug>(FileBeagleBufferBgSplitVerticalVisitTarget)         :<C-U>call b:dirvish.visit_target("rightbelow vert sp", 1)<CR>
        let l:default_normal_plug_map['FileBeagleBufferBgSplitVerticalVisitTarget'] = g:filebeagle_buffer_background_key_map_prefix . 'v'
        vnoremap <Plug>(FileBeagleBufferBgSplitVerticalVisitTarget)         :call b:dirvish.visit_target("rightbelow vert sp", 1)<CR>
        let l:default_visual_plug_map['FileBeagleBufferBgSplitVerticalVisitTarget'] = g:filebeagle_buffer_background_key_map_prefix . 'v'

        nnoremap <Plug>(FileBeagleBufferSplitVisitTarget)                   :<C-U>call b:dirvish.visit_target("sp", 0)<CR>
        let l:default_normal_plug_map['FileBeagleBufferSplitVisitTarget'] = 's'
        vnoremap <Plug>(FileBeagleBufferSplitVisitTarget)                   :call b:dirvish.visit_target("sp", 0)<CR>
        let l:default_visual_plug_map['FileBeagleBufferSplitVisitTarget'] = 's'
        nnoremap <Plug>(FileBeagleBufferBgSplitVisitTarget)                 :<C-U>call b:dirvish.visit_target("rightbelow sp", 1)<CR>
        let l:default_normal_plug_map['FileBeagleBufferBgSplitVisitTarget'] = g:filebeagle_buffer_background_key_map_prefix . 's'
        vnoremap <Plug>(FileBeagleBufferBgSplitVisitTarget)                 :call b:dirvish.visit_target("rightbelow sp", 1)<CR>
        let l:default_visual_plug_map['FileBeagleBufferBgSplitVisitTarget'] = g:filebeagle_buffer_background_key_map_prefix . 's'

        nnoremap <Plug>(FileBeagleBufferTabVisitTarget)                     :<C-U>call b:dirvish.visit_target("tabedit", 0)<CR>
        let l:default_normal_plug_map['FileBeagleBufferTabVisitTarget'] = 't'
        vnoremap <Plug>(FileBeagleBufferTabVisitTarget)                     :call b:dirvish.visit_target("tabedit", 0)<CR>
        let l:default_visual_plug_map['FileBeagleBufferTabVisitTarget'] = 't'
        nnoremap <Plug>(FileBeagleBufferBgTabVisitTarget)                   :<C-U>call b:dirvish.visit_target("tabedit", 1)<CR>
        let l:default_normal_plug_map['FileBeagleBufferBgTabVisitTarget'] = g:filebeagle_buffer_background_key_map_prefix . 't'
        vnoremap <Plug>(FileBeagleBufferBgTabVisitTarget)                   :call b:dirvish.visit_target("tabedit", 1)<CR>
        let l:default_visual_plug_map['FileBeagleBufferBgTabVisitTarget'] = g:filebeagle_buffer_background_key_map_prefix . 't'

        """ Focal directory changing
        nnoremap <Plug>(FileBeagleBufferFocusOnParent)                      :call b:dirvish.visit_parent_dir()<CR>
        let l:default_normal_plug_map['FileBeagleBufferFocusOnParent'] = '-'
        nnoremap <Plug>(FileBeagleBufferFocusOnPrevious)                    :call b:dirvish.visit_prev_dir()<CR>
        let l:default_normal_plug_map['FileBeagleBufferFocusOnPrevious'] = 'b'
        nmap <buffer> <silent> <BS> <Plug>(FileBeagleBufferFocusOnPrevious)
        nmap <buffer> <silent> u    <BS>

        call extend(l:default_normal_plug_map, get(g:, 'filebeagle_buffer_normal_key_maps', {}))

        for plug_name in keys(l:default_normal_plug_map)
            let plug_key = l:default_normal_plug_map[plug_name]
            if !empty(plug_key)
                execute "nmap <buffer> <silent> " . plug_key . " <Plug>(".plug_name.")"
            endif
        endfor

        if exists("g:filebeagle_buffer_visual_key_maps")
            call extend(l:default_visual_plug_map, g:filebeagle_buffer_visual_key_maps)
        endif

        for plug_name in keys(l:default_visual_plug_map)
            let plug_key = l:default_visual_plug_map[plug_name]
            if !empty(plug_key)
                execute "vmap <buffer> <silent> " . plug_key . " <Plug>(".plug_name.")"
            endif
        endfor

    endfunction

    function! l:directory_viewer.render_buffer() abort dict
        call s:sanity_check()
        let w = winsaveview()


        setlocal modifiable
        %delete

        let self.jump_map = {}
        call self.setup_buffer_syntax()
        let paths = s:discover_paths(self.focus_dir, "*", self.is_include_hidden)
        for path in paths[0] + paths[1]
            let tail = fnamemodify(path["full_path"], ':t')
            if !isdirectory(path["full_path"]), && self.is_filtered && !empty(self.filter_exp) && (tail !~# self.filter_exp)
                continue
            endif
            let self.jump_map[line("$")] = {
                        \ "full_path" : path["full_path"],
                        \ "dirname" : path["dirname"],
                        \ }
            call append(line("$")-1, path["full_path"])
        endfor

        $delete " remove extra last line
        setlocal nomodifiable nomodified
        call winrestview(w)
        let self.default_targets[self.focus_dir] = self.focus_file
        call self.goto_pattern(self.focus_file)
    endfunction

    function! l:directory_viewer.quit_buffer() dict
        "tickle original 'alt' buffer
        if self.orig_alt_buf_num != self.buf_num && bufexists(self.orig_alt_buf_num)
            exe 'b ' . self.orig_alt_buf_num
        endif

        "restore original buffer
        if self.prev_buf_num != self.buf_num && bufexists(self.prev_buf_num)
            exe 'b ' . self.prev_buf_num
        else
            silent! bdelete
        endif
    endfunction

    function! l:directory_viewer.new_viewer(split_cmd) dict
        execute "silent keepalt keepjumps " . a:split_cmd . " " . bufname(self.prev_buf_num)
        let d = s:new_dirvish()
        call d.open_dir(
                    \ -1,
                    \ self.focus_dir,
                    \ self.focus_file,
                    \ self.prev_buf_num,
                    \ self.prev_focus_dirs,
                    \ self.default_targets_for_directory,
                    \ self.is_filtered,
                    \ self.filter_exp,
                    \ self.is_include_hidden,
                    \ )
    endfunction

    function! l:directory_viewer.visit_target(split_cmd, open_in_background) dict range
        let l:start_line = !v:count ? a:firstline : v:count
        let l:end_line   = !v:count ? a:lastline  : v:count

        let l:num_dir_targets = 0
        let l:selected_entries = []
        for l:cur_line in range(l:start_line, l:end_line)
            if !has_key(self.jump_map, l:cur_line)
                " call s:notifier.info("Line " . l:cur_line . " is not a valid navigation entry")
                return 0
            endif
            if isdirectory(self.jump_map[l:cur_line].full_path)
                let l:num_dir_targets += 1
            endif
            call add(l:selected_entries, self.jump_map[l:cur_line])
        endfor

        if l:num_dir_targets > 1 || (l:num_dir_targets == 1 && len(l:selected_entries) > 1)
            call s:notifier.info("Cannot open multiple selections that include directories")
            return 0
        endif

        if l:num_dir_targets == 1
            let l:cur_tab_num = tabpagenr()
            let l:entry = l:selected_entries[0]
            let l:target = l:entry.full_path
            if !isdirectory(l:target)
                call s:notifier.error("cannot open: '" . l:target . "'")
                return 0
            endif

            let isdotdot = l:entry.full_path =~# "\.\.[\\\/]$"
            let new_focus_file = isdotdot
                    \ ? s:base_dirname(self.focus_dir)
                    \ : (a:split_cmd ==# "edit"
                    \     ? get(self.default_targets, l:target, "")
                    \     : l:target)

            if a:split_cmd == "edit"
                call self.set_focus_dir(l:target, new_focus_file,  1)
            else
                if !a:open_in_background || a:split_cmd ==# "tabedit"
                    execute "silent keepalt keepjumps " . a:split_cmd . " " . bufname(self.prev_buf_num)
                else
                    execute "silent keepalt keepjumps " . a:split_cmd
                endif
                let d = s:new_dirvish()
                call d.open_dir(
                            \ l:target,
                            \ new_focus_file,
                            \ self.prev_buf_num,
                            \ self.prev_focus_dirs,
                            \ self.default_targets,
                            \ self.is_filtered,
                            \ self.filter_exp,
                            \ self.is_include_hidden,
                            \ )
                if a:open_in_background
                    execute "tabnext " . l:cur_tab_num
                    execute bufwinnr(self.buf_num) . "wincmd w"
                endif
            endif
        else
            call self.visit_files(l:selected_entries, a:split_cmd, a:open_in_background)
        endif
    endfunction

    function! l:directory_viewer.set_focus_dir(new_dir, focus_file, add_to_history) dict
        if a:add_to_history && exists("self['focus_dir']")
            if empty(self.prev_focus_dirs) || self.prev_focus_dirs[-1][0] != self.focus_dir
                call add(self.prev_focus_dirs, [self.focus_dir, self.focus_file])
            endif
        endif
        let self.focus_dir = fnamemodify(a:new_dir, ":p")
        let self.focus_file = a:focus_file
    endfunction

    function! l:directory_viewer.visit_files(selected_entries, split_cmd, open_in_background)
        if len(a:selected_entries) < 1
            return
        endif
        let l:cur_tab_num = tabpagenr()
        let old_lazyredraw = &lazyredraw
        set lazyredraw
        let l:split_cmd = a:split_cmd
        if !a:open_in_background
            execute "silent keepalt keepjumps buffer " . self.prev_buf_num
        endif
        let l:opened_files = []
        for l:entry in a:selected_entries
            let l:path_to_open = fnameescape(l:entry.full_path)
            try
                execute l:split_cmd . " " . l:path_to_open
            catch /E37:/ " E37: No write since last change
                call s:notifier.info("E37: No write since last change")
                return
            catch /E36:/ " E36: no room for any new splits; open in-situ.
                let l:split_cmd = "edit"
                execute "edit " . l:path_to_open
            catch /E325:/ " E325: swap file exists
                call s:notifier.info("E325: swap file exists")
            endtry
            call add(l:opened_files, '"' . fnamemodify(l:entry.full_path, ':t') . '"')
        endfor
        if a:open_in_background
            execute "tabnext " . l:cur_tab_num
            execute bufwinnr(self.buf_num) . "wincmd w"
            if a:split_cmd == "edit"
                execute "silent keepalt keepjumps buffer " .self.buf_num
            endif
            redraw!
            if a:split_cmd == "edit"
                " It makes sense (to me, at least) to go to the last buffer
                " selected & opened upon closing FileBeagle when in this
                " combination of modes (i.e., split = 'edit' and in
                " background)
                let new_prev_buf_num = bufnr(a:selected_entries[-1].full_path)
                if new_prev_buf_num > 0
                    let self.prev_buf_num = new_prev_buf_num
                endif
                if len(l:opened_files) > 1
                    " Opening multiple in background of same window is a little
                    " cryptic so in this special case, we issue some feedback
                    echo join(l:opened_files, ", ")
                endif
            endif
        else
            execute "silent! bwipe! " . self.buf_num
            " redraw!
        endif
        let &lazyredraw = l:old_lazyredraw
    endfunction

    function! l:directory_viewer.visit_parent_dir() dict
        let pdir = s:parent_dir(self.focus_dir)
        if pdir != self.focus_dir
            let new_focus_file = s:base_dirname(self.focus_dir)
            call self.set_focus_dir(pdir, new_focus_file, 1)
        else
            call s:notifier.info("no parent directory")
        endif
    endfunction

    function! l:directory_viewer.visit_prev_dir() dict
        if empty(self.prev_focus_dirs)
            call s:notifier.info("no previous directory")
        else
            let new_focus_dir = self.prev_focus_dirs[-1][0]
            let new_focus_file = self.prev_focus_dirs[-1][1]
            call remove(self.prev_focus_dirs, -1)
            call self.set_focus_dir(new_focus_dir, new_focus_file, 0)
        endif
    endfunction

    function! l:directory_viewer.goto_pattern(pattern) dict
        let full_pattern = '^\V\C' . escape(a:pattern, '/\') . '$'
        call search(full_pattern, "cw")
    endfunction

    function! l:directory_viewer.set_filter_exp() dict
        let self.filter_exp = input("filter (regex): ", self.filter_exp)
        if empty(self.filter_exp)
            let self.is_filtered = 0
            call s:notifier.info("filter disabled")
        else
            let self.is_filtered = 1
            call s:notifier.info("filter enabled")
        endif
        call self.render_buffer()
    endfunction

    function! l:directory_viewer.toggle_filter() dict
        if self.is_filtered
            let self.is_filtered = 0
            call s:notifier.info("filter disabled")
            call self.render_buffer()
        else
            if !empty(self.filter_exp)
                let self.is_filtered = 1
                call s:notifier.info("filter enabled")
                call self.render_buffer()
            else
                call self.set_filter_exp()
            endif
        endif
    endfunction

    function! l:directory_viewer.toggle_hidden() dict
        if self.is_include_hidden
            let self.is_include_hidden = 0
            call s:notifier.info("excluding hidden files")
        else
            let self.is_include_hidden = 1
            call s:notifier.info("showing hidden files")
        endif
        call self.render_buffer()
    endfunction

    return l:directory_viewer
endfunction

" Command Interface {{{1
" =============================================================================

function! filebeagle#FileBeagleOpen(focus_dir)
    if exists("b:dirvish")
        call s:notifier.info("already open")
        return
    endif

    if empty(a:focus_dir)
        "open current _buffer_ directory
        let focus_dir = empty(expand("%", 1)) ? getcwd() : expand('%:p:h', 1)
    else
        let focus_dir = fnamemodify(a:focus_dir, ":p")
    endif

    if !isdirectory(focus_dir)
        call s:notifier.error("invalid directory: '" . focus_dir . "'")
    else
        call d.open_dir(
                    \ buf,
                    \ focus_dir,
                    \ bufname("%"),
                    \ bufnr("%"),
                    \ [],
                    \ {},
                    \ 0,
                    \ "",
                    \ g:filebeagle_show_hidden,
                    \ g:filebeagle_show_hidden
                    \)
    endif
endfunction

unlet! s:notifier
let s:notifier = s:new_notifier("")

" vim:foldlevel=4:
