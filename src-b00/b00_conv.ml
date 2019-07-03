(*---------------------------------------------------------------------------
   Copyright (c) 2019 The b0 programmers. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
   %%NAME%% %%VERSION%%
  ---------------------------------------------------------------------------*)

open B0_std
open B00

(* Binary encoding *)

module Bin = struct
  let err i fmt = Fmt.failwith_notrace ("%d: " ^^ fmt) i
  let err_byte ~kind i b =
    err i "corrupted input, unexpected byte 0x%x for %s" b kind

  let check_next ~kind s i next =
   if next <= String.length s then () else
   err i  "unexpected end of input, expected %d bytes for %s" (next - i) kind

  let get_byte s i = Char.code (String.get s i) [@@ocaml.inline]

  let dec_eoi s i =
    if i = String.length s then () else
    err i "expected end of input (len: %d)" (String.length s)

  let enc_magic b magic = Buffer.add_string b magic
  let dec_magic s i magic =
    let next = i + String.length magic in
    check_next ~kind:magic s i next;
    let magic' = String.with_index_range ~first:i ~last:(next - 1) s in
    if String.equal magic magic' then next else
    err i "magic mismatch: %S but expected %S" magic' magic

  let enc_byte b n =
    Buffer.add_char b (Char.chr (n land 0xFF)) [@@ocaml.inline]

  let dec_byte ~kind s i =
    let next = i + 1 in
    check_next ~kind s i next;
    let b = get_byte s i in
    next, b
  [@@ocaml.inline]

  let enc_unit b () = enc_byte b 0
  let dec_unit s i =
    let kind = "unit" in
    let next, b = dec_byte ~kind s i in
    match b with
    | 0 -> next, ()
    | b -> err_byte ~kind i b

  let enc_bool b bool = enc_byte b (if bool then 1 else 0)
  let dec_bool s i =
    let kind = "bool" in
    let next, b = dec_byte ~kind s i in
    match b with
    | 0 -> next, false
    | 1 -> next, true
    | b -> err_byte ~kind i b

  let enc_int b n =
    let w = enc_byte in
    w b n; w b (n lsr 8); w b (n lsr 16); w b (n lsr 24);
    if Sys.word_size = 32 then (w b 0x00; w b 0x00; w b 0x00; w b 0x00) else
    (w b (n lsr 32); w b (n lsr 40); w b (n lsr 48); w b (n lsr 56))

  let dec_int s i =
    let r = get_byte in
    let next = i + 8 in
    check_next ~kind:"int" s i next;
    let b0 = r s (i    ) and b1 = r s (i + 1)
    and b2 = r s (i + 2) and b3 = r s (i + 3) in
    let n = (b3 lsl 24) lor (b2 lsl 16) lor (b1 lsl 8) lor b0 in
    if Sys.word_size = 32 then next, n else
    let b4 = r s (i + 4) and b5 = r s (i + 5)
    and b6 = r s (i + 6) and b7 = r s (i + 7) in
    next, (b7 lsl 56) lor (b6 lsl 48) lor (b5 lsl 40) lor (b4 lsl 32) lor n

  let enc_int64 b i =
    (* XXX From 4.08 on use Buffer.add_int64_le *)
    let w = enc_byte in
    let i0 = Int64.to_int i in
    let i1 = Int64.to_int (Int64.shift_right_logical i 16) in
    let i2 = Int64.to_int (Int64.shift_right_logical i 32) in
    let i3 = Int64.to_int (Int64.shift_right_logical i 48) in
    let b0 = i0 and b1 = i0 lsr 8 and b2 = i1 and b3 = i1 lsr 8
    and b4 = i2 and b5 = i2 lsr 8 and b6 = i3 and b7 = i3 lsr 8 in
    w b b0; w b b1; w b b2; w b b3; w b b4; w b b5; w b b6; w b b7

  external swap64 : int64 -> int64 = "%bswap_int64"
  external unsafe_get_int64_ne : string -> int -> int64 = "%caml_string_get64u"

  let unsafe_get_int64_le b i = match Sys.big_endian with
  | true -> swap64 (unsafe_get_int64_ne b i)
  | false -> unsafe_get_int64_ne b i

  let dec_int64 s i =
    let next = i + 8 in
    check_next ~kind:"int64" s i next;
    next, unsafe_get_int64_le s i

  let enc_string b s =
    enc_int b (String.length s);
    Buffer.add_string b s

  let dec_string s i =
    let i, len = dec_int s i in
    let next = i + len in
    check_next ~kind:"string" s i next;
    next, String.sub s i len

  let enc_fpath b p = enc_string b (Fpath.to_string p)
  let dec_fpath s i =
    let next, s = dec_string s i in
    match Fpath.of_string s with
    | Error e -> err i "corrupted file path value: %s" e
    | Ok p -> next, p

  let enc_list el b l =
    let rec loop len acc = function
    | [] -> len, acc | v :: vs -> loop (len + 1) (v :: acc) vs
    in
    let len, rl = loop 0 [] l in
    enc_int b len;
    let rec loop el b = function [] -> () | v :: vs -> el b v; loop el b vs in
    loop el b rl

  let dec_list el s i  =
    let i, count = dec_int s i in
    let rec loop el s i count acc = match count = 0 with
    | true -> i, acc (* enc_list writes the reverse list. *)
    | false ->
        let i, v = el s i in
        loop el s i (count - 1) (v :: acc)
    in
    loop el s i count []

  let enc_option w b = function
  | None -> enc_byte b 0
  | Some v -> enc_byte b 1; w b v

  let dec_option some s i =
    let kind = "option" in
    let next, b = dec_byte ~kind s i in
    match b with
    | 0 -> next, None
    | 1 -> let i, v = some s next in i, Some v
    | b -> err_byte ~kind i b

  let enc_result ~ok ~error b = function
  | Ok v -> enc_byte b 0; ok b v
  | Error e -> enc_byte b 1; error b e

  let dec_result ~ok ~error s i =
    let kind = "result" in
    let next, b = dec_byte ~kind s i in
    match b with
    | 0 -> let i, v = ok s next in i, Ok v
    | 1 -> let i, e = error s next in i, Error e
    | b -> err_byte ~kind i b
end

module File_cache = struct
  let pp_feedback ppf = function
  | `File_cache_need_copy p ->
      Fmt.pf ppf "@[Warning: need copy: %a@]" Fpath.pp_quoted p
end

module Guard = struct
  let pp_feedback ppf = function
  | `File_status_repeat f ->
      Fmt.pf ppf "%a: file status repeated" Fpath.pp_quoted f
  | `File_status_unstable f ->
      Fmt.pf ppf "%a: file status unstable" Fpath.pp_quoted f
end

module Op = struct
  let file_read_color = [`Faint; `Fg `Magenta ]
  let file_write_color = [`Faint; `Fg `Green]
  let file_wait_color = [`Faint]
  let file_delete_color = [`Faint; `Fg `Red]
  let hash_color = [`Fg `Cyan]
  let pp_file_read = Fmt.tty file_read_color Fpath.pp_quoted
  let pp_file_write = Fmt.tty file_write_color Fpath.pp_quoted
  let pp_file_wait = Fmt.tty file_wait_color Fpath.pp_quoted
  let pp_file_delete = Fmt.tty file_delete_color Fpath.pp_quoted
  let pp_hash = Fmt.tty hash_color Hash.pp
  let pp_file_contents = Fmt.truncated ~max:150
  let pp_error_msg ppf e = Fmt.pf ppf "@[error: %s@]" e
  let pp_subfield s f pp =
    Fmt.field ~label:(Fmt.tty_string [`Faint; `Fg `Yellow]) s f pp


  module Spawn = struct

    (* Formatting *)

    let pp_success_exits ppf = function
    | [] -> Fmt.string ppf "any"
    | cs -> Fmt.(list ~sep:comma int) ppf cs

    let pp_cmd ppf s =
      (* XXX part of this could maybe moved to B0_std.Cmd. *)
      let args = Cmd.to_list (Op.Spawn.args s) in
      let quote = Filename.quote in
      let pp_brack = Fmt.tty_string [`Fg `Yellow] in
      let pp_arg ppf a = Fmt.pf ppf "%s" (quote a) in
      let pp_o_arg ppf a = Fmt.tty_string file_write_color ppf (quote a) in
      let rec pp_args last_was_o ppf = function
      | [] -> ()
      | a :: args ->
          Fmt.char ppf ' ';
          if last_was_o then pp_o_arg ppf a else pp_arg ppf a;
          pp_args (String.equal a "-o") ppf args
      in
      let pp_stdin ppf = function
      | None -> ()
      | Some file -> Fmt.pf ppf "< %s" (quote (Fpath.to_string file))
      in
      let pp_stdo redir ppf = function
      | `Ui -> ()
      | `Tee f | `File f ->
          Fmt.pf ppf " %s %a" redir pp_o_arg (Fpath.to_string f)
      in
      Fmt.pf ppf "@[<h>"; pp_brack ppf "[";
      Cmd.pp_tool ppf (Op.Spawn.tool s); pp_args false ppf args;
      pp_stdin ppf (Op.Spawn.stdin s);
      pp_stdo ">" ppf (Op.Spawn.stdout s);
      pp_stdo "2>" ppf (Op.Spawn.stderr s);
      pp_brack ppf "]"; Fmt.pf ppf "@]"

    let pp_stdo ppf = function
    | `Ui -> Fmt.pf ppf "<ui>"
    | `File f -> Fpath.pp_quoted ppf f
    | `Tee f -> Fmt.pf ppf "@[<hov><ui> and@ %a@]" Fpath.pp_quoted f

    let pp_stdo_ui ~truncate ppf s = match (Op.Spawn.stdo_ui s) with
    | None -> Fmt.none ppf ()
    | Some (Ok d) ->
        if truncate then pp_file_contents ppf d else String.pp ppf d
    | Some (Error e) -> pp_error_msg ppf e

    let pp_result ppf = function
    | Ok st -> Os.Cmd.pp_status ppf st
    | Error e -> pp_error_msg ppf e

    let pp =
      let pp_env = Fmt.(vbox @@ list string) in
      let pp_opt_path = Fmt.(option ~none:none) Fpath.pp_quoted in
      let pp_stdio =
        Fmt.concat ~sep:Fmt.sp @@
        [ pp_subfield "stdin" Op.Spawn.stdin pp_opt_path;
          pp_subfield "stderr" Op.Spawn.stderr pp_stdo;
          pp_subfield "stdout" Op.Spawn.stdout pp_stdo; ]
      in
      Fmt.concat @@
      [ Fmt.field "cmd" Fmt.id pp_cmd;
        Fmt.field "result" Op.Spawn.result pp_result;
        Fmt.field "stdo-ui" Fmt.id (pp_stdo_ui ~truncate:false);
        Fmt.field "cwd" Op.Spawn.cwd Fpath.pp_quoted;
        Fmt.field "env" Op.Spawn.env pp_env;
        Fmt.field "relevant-env" Op.Spawn.relevant_env pp_env;
        Fmt.field "stdio" Fmt.id pp_stdio;
        Fmt.field "success-exits" Op.Spawn.success_exits pp_success_exits; ]
  end

  module Read = struct
    let pp_result ppf = function
    | Error e -> pp_error_msg ppf e
    | Ok d -> pp_file_contents ppf d

    let pp =
      Fmt.concat @@
      [ Fmt.field "file" Op.Read.file pp_file_read;
        Fmt.field "result" Op.Read.result pp_result ]
  end

  module Write = struct
    let pp_result ppf = function
    | Error e -> pp_error_msg ppf e
    | Ok () -> Fmt.string ppf "written"

    let pp =
      Fmt.concat @@
      [ Fmt.field "file" Op.Write.file pp_file_write;
        Fmt.field "mode" Op.Write.mode Fmt.int;
        Fmt.field "result" Op.Write.result pp_result; ]
  end

  module Copy = struct
    let pp_result ppf = function
    | Error e -> pp_error_msg ppf e
    | Ok () -> Fmt.string ppf "copied"

    let pp = Fmt.field "result" Op.Copy.result pp_result
  end

  module Delete = struct
    let pp_result ppf = function
    | Error e -> pp_error_msg ppf e
    | Ok () -> Fmt.string ppf "deleted"

    let pp =
      Fmt.concat @@
      [ Fmt.field "path" Op.Delete.path pp_file_delete;
        Fmt.field "result" Op.Delete.result pp_result ]
  end

  module Mkdir = struct
    let pp_result ppf = function
    | Error e -> pp_error_msg ppf e
    | Ok created -> Fmt.string ppf (if created then "created" else "existed")

    let pp =
      Fmt.concat @@
      [ Fmt.field "dir" Op.Mkdir.dir pp_file_write;
        Fmt.field "result" Op.Mkdir.result pp_result ]
  end

  module Wait_files = struct
  end

  (* Formatting *)

  let pp_op_hash ppf o =
    let h = Op.hash o in
    if Hash.is_nil h then () else pp_hash ppf h

  let kind_name_padded = function
  | Op.Spawn _ -> "spawn" | Read _ -> "read" | Write _ -> "write"
  | Copy _ -> "copy" | Delete _ -> "delet" | Mkdir _ -> "mkdir"
  | Wait_files _ -> "wait"

  let pp_status ppf v = Fmt.string ppf @@ match v with
  | Op.Waiting -> "waiting" | Executed -> "executed"
  | Failed -> "failed" | Aborted -> "aborted"

  let pp_kind_full ppf = function
  | Op.Spawn s -> Spawn.pp ppf s
  | Op.Read r -> Read.pp ppf r
  | Op.Write w -> Write.pp ppf w
  | Op.Copy c -> Copy.pp ppf c
  | Op.Delete d -> Delete.pp ppf d
  | Op.Mkdir m -> Mkdir.pp ppf m
  | Op.Wait_files _ -> ()

  let pp_kind_short ppf o = match Op.kind o with
  | Op.Copy c ->
      Fmt.pf ppf "%a to %a"
        pp_file_read (Op.Copy.src c) pp_file_write (Op.Copy.dst c)
  | Op.Delete d -> pp_file_delete ppf (Op.Delete.path d)
  | Op.Mkdir m -> pp_file_write ppf (Op.Mkdir.dir m)
  | Op.Read r -> pp_file_read ppf (Op.Read.file r)
  | Op.Spawn s -> Spawn.pp_cmd ppf s
  | Op.Write w -> pp_file_write ppf (Op.Write.file w)
  | Op.Wait_files _ ->
      Fmt.pf ppf "@[<v>%a@]" (Fmt.list pp_file_wait) (Op.reads o)

  let pp_kind_micro ppf o = match Op.kind o with
  | Op.Copy c ->  pp_file_write ppf (Op.Copy.dst c)
  | Op.Delete d -> pp_file_delete ppf (Op.Delete.path d)
  | Op.Mkdir m -> pp_file_write ppf (Op.Mkdir.dir m)
  | Op.Read r -> pp_file_read ppf (Op.Read.file r)
  | Op.Spawn s -> Cmd.pp_tool ppf (Op.Spawn.tool s)
  | Op.Wait_files w ->
      begin match Op.reads o with
      | [f] -> pp_file_wait ppf f
      | _ -> Fmt.string ppf "*"
      end
  | Op.Write w -> pp_file_write ppf (Op.Write.file w)

  let pp_short_status ppf o = match Op.status o with
  | Op.Executed ->
      begin match Op.revived o with
      | true -> Fmt.tty_string [`Fg `Magenta; `Faint ] ppf "R"
      | false -> Fmt.tty_string [`Fg `Magenta;] ppf "E"
      end
  | Op.Failed -> Fmt.tty_string [`Fg `Red] ppf "FAILED"
  | Op.Aborted -> Fmt.tty_string [`Faint; `Fg `Red] ppf "ABORTED"
  | Op.Waiting -> Fmt.tty_string [`Fg `Cyan] ppf "W"

  let pp_header ppf o =
    Fmt.pf ppf "[%a %03d %a %a]"
      pp_short_status o (Op.id o) (Fmt.tty_string [`Fg `Green])
      (kind_name_padded (Op.kind o))
      Time.Span.pp (B00.Op.duration o)

  let pp_short ppf o =
    Fmt.pf ppf "@[<h>%a %a %a@]"
      pp_header o pp_kind_short o pp_op_hash o

  let pp_short_with_ui ppf o = match Op.kind o with
  | Op.Spawn s ->
      begin match Op.Spawn.stdo_ui s with
      | None -> pp_short ppf o
      | Some _ ->
          Fmt.pf ppf "@[<v>@[<h>%a:@]@,%a@]"
            pp_short o (Spawn.pp_stdo_ui ~truncate:false) s
      end
  | _ -> pp_short ppf o

  let pp =
    let pp_span = Time.Span.pp in
    let pp_reads = Fmt.braces (Fmt.list pp_file_read) in
    let pp_writes = Fmt.braces (Fmt.list pp_file_write) in
    let pp_timings =
      let wait o = Time.Span.abs_diff (Op.time_created o) (Op.time_started o) in
      Fmt.box @@ Fmt.concat ~sep:Fmt.sp @@
      [ pp_subfield "duration" Op.duration pp_span;
        pp_subfield "created" Op.time_created pp_span;
        pp_subfield "started" Op.time_started pp_span;
        pp_subfield "waited" wait pp_span; ]
    in
    let pp_caching =
      Fmt.box @@ Fmt.concat ~sep:Fmt.sp @@
      [ pp_subfield "hash" Op.hash pp_hash;
        pp_subfield "revived" Op.revived Fmt.bool ]
    in
    Fmt.vbox ~indent:1 @@ Fmt.concat [
      pp_header;
      Fmt.field "group" Op.group Fmt.string;
      Fmt.using Op.kind pp_kind_full;
      Fmt.field "caching" Fmt.id pp_caching;
      Fmt.field "timings" Fmt.id pp_timings;
      Fmt.field "reads" Op.reads pp_reads;
      Fmt.field "writes" Op.writes pp_writes ]

  let pp_short_log = pp_short
  let pp_normal_log = pp_short_with_ui
  let pp_long_log = pp

  let pp_did_not_write ~op_howto ppf (o, fs) =
    let pp_file_list = Fmt.list pp_file_write in
    let exp = match fs with
    | [_] -> "this expected file"
    |  _  -> "these expected files"
    in
    Fmt.pf ppf "@[<v>%a:@,@[%a %s: %a@]@, @[%a@]@]"
      pp_short o (Fmt.tty [`Fg `Red] Fmt.string) "Operation did not write" exp
      (Fmt.tty [`Faint] op_howto) o pp_file_list fs

  let pp_spawn_exit ppf s = match Op.Spawn.result s with
  | Error e -> Fmt.pf ppf "@,%s" e
  | Ok (`Signaled c) -> Fmt.pf ppf "[signaled:%d]" c
  | Ok (`Exited c) as result ->
      match Op.Spawn.success_exits s with
      | ([] | [0]) when c <> 0 -> Fmt.pf ppf "[%d]" c
      | cs ->
          Fmt.pf ppf "@,@[<h>Error: %a expected: %a@]"
            (Fmt.tty [`Fg `Red] Spawn.pp_result) result
            Spawn.pp_success_exits cs

  let pp_spawn_status_fail ppf o =
    let s = Op.Spawn.get o in
    Fmt.pf ppf "@[<v>%a%a@,%a@]"
      pp_short o pp_spawn_exit s
      (Spawn.pp_stdo_ui ~truncate:false) s

  let pp_failed ~op_howto ppf (op, (`Did_not_write fs)) = match fs with
  | [] ->
      begin match Op.kind op with
      | Op.Spawn _ -> pp_spawn_status_fail ppf op
      | _ -> pp ppf op
      end
  | fs -> pp_did_not_write ppf ~op_howto (op, fs)

  (* Binary serialization *)

  let enc_time_span b s = Bin.enc_int64 b (Time.Span.to_uint64_ns s)
  let dec_time_span s i =
    let i, u = Bin.dec_int64 s i in
    i, Time.Span.of_uint64_ns u

  let enc_hash b h = Bin.enc_string b (Hash.to_bytes h)
  let dec_hash s i =
    let i, s = Bin.dec_string s i in
    i, Hash.of_bytes s

  let enc_status b = function
  | Op.Aborted -> Bin.enc_byte b 0
  | Op.Executed -> Bin.enc_byte b 1
  | Op.Failed -> Bin.enc_byte b 2
  | Op.Waiting -> Bin.enc_byte b 3

  let dec_status s i =
    let kind = "Op.status" in
    let next, b = Bin.dec_byte ~kind s i in
    match b with
    | 0 -> next, Op.Aborted
    | 1 -> next, Op.Executed
    | 2 -> next, Op.Failed
    | 3 -> next, Op.Waiting
    | b -> Bin.err_byte ~kind i b

  let enc_copy b c =
    Bin.enc_fpath b (Op.Copy.src c);
    Bin.enc_fpath b (Op.Copy.dst c);
    Bin.enc_int b (Op.Copy.mode c);
    Bin.enc_option Bin.enc_int b (Op.Copy.linenum c);
    Bin.enc_result ~ok:Bin.enc_unit ~error:Bin.enc_string b (Op.Copy.result c)

  let dec_copy s i =
    let i, src = Bin.dec_fpath s i in
    let i, dst = Bin.dec_fpath s i in
    let i, mode = Bin.dec_int s i in
    let i, linenum = Bin.dec_option Bin.dec_int s i in
    let i, result = Bin.dec_result ~ok:Bin.dec_unit ~error:Bin.dec_string s i in
    i, Op.Copy.v ~src ~dst ~mode ~linenum ~result

  let enc_delete b d =
    Bin.enc_fpath b (Op.Delete.path d);
    Bin.enc_result ~ok:Bin.enc_unit ~error:Bin.enc_string b (Op.Delete.result d)

  let dec_delete s i =
    let i, path = Bin.dec_fpath s i in
    let i, result = Bin.dec_result ~ok:Bin.dec_unit ~error:Bin.dec_string s i in
    i, Op.Delete.v ~path ~result

  let enc_mkdir b m =
    Bin.enc_fpath b (Op.Mkdir.dir m);
    Bin.enc_result ~ok:Bin.enc_bool ~error:Bin.enc_string b (Op.Mkdir.result m)

  let dec_mkdir s i =
    let i, dir = Bin.dec_fpath s i in
    let i, result = Bin.dec_result ~ok:Bin.dec_bool ~error:Bin.dec_string s i in
    i, Op.Mkdir.v ~dir ~result

  let enc_read b r = (* we don't save the data it's already on the FS *)
    Bin.enc_fpath b (Op.Read.file r);
    let r = Result.bind (Op.Read.result r) @@ fun _ -> Ok () in
    Bin.enc_result ~ok:Bin.enc_unit ~error:Bin.enc_string b r

  let dec_read s i =
    let i, file = Bin.dec_fpath s i in
    let i, result = Bin.dec_result ~ok:Bin.dec_unit ~error:Bin.dec_string s i in
    let result = Result.bind result @@ fun _ -> Ok "<see read file>" in
    i, Op.Read.v ~file ~result

  let enc_spawn_stdo b = function
  | `Ui -> Bin.enc_byte b 0
  | `File p -> Bin.enc_byte b 1; Bin.enc_fpath b p
  | `Tee p -> Bin.enc_byte b 1; Bin.enc_fpath b p

  let dec_spawn_stdo s i =
    let kind = "Op.spawn_stdo" in
    let next, b = Bin.dec_byte ~kind s i in
    match b with
    | 0 -> next, `Ui
    | 1 -> let i, p = Bin.dec_fpath s next in i, `File p
    | 2 -> let i, p = Bin.dec_fpath s next in i, `Tee p
    | b -> Bin.err_byte ~kind i b

  let enc_cmd b cmd =
    let arg b a = Bin.enc_byte b 0; Bin.enc_string b a in
    let shield b = Bin.enc_byte b 1 in
    let append b = Bin.enc_byte b 2 in
    let empty b = Bin.enc_byte b 3 in
    Cmd.iter_enc ~arg ~shield ~append ~empty b cmd

  let rec dec_cmd s i =
    let kind = "Cmd.t" in
    let next, b = Bin.dec_byte ~kind s i in
    match b with
    | 0 -> let i, s = Bin.dec_string s next in i, Cmd.arg s
    | 1 -> let i, cmd = dec_cmd s next in i, Cmd.shield cmd
    | 2 ->
        let i, cmd0 = dec_cmd s next in
        let i, cmd1 = dec_cmd s i in
        i, Cmd.append cmd1 cmd0
    | 3 -> next, Cmd.empty
    | b -> Bin.err_byte ~kind i b

  let enc_os_cmd_status b = function
  | `Exited c -> Bin.enc_byte b 0; Bin.enc_int b c
  | `Signaled c -> Bin.enc_byte b 1; Bin.enc_int b c

  let dec_os_cmd_status s i =
    let kind = "Os.Cmd.status" in
    let next, b = Bin.dec_byte ~kind s i in
    match b with
    | 0 -> let i, c = Bin.dec_int s next in i, `Exited c
    | 1 -> let i, c = Bin.dec_int s next in i, `Signaled c
    | b -> Bin.err_byte ~kind i b

  let enc_spawn b s =
    Bin.enc_list Bin.enc_string b (Op.Spawn.env s);
    Bin.enc_list Bin.enc_string b (Op.Spawn.relevant_env s);
    Bin.enc_fpath b (Op.Spawn.cwd s);
    Bin.enc_option Bin.enc_fpath b (Op.Spawn.stdin s);
    enc_spawn_stdo b (Op.Spawn.stdout s);
    enc_spawn_stdo b (Op.Spawn.stderr s);
    Bin.enc_list Bin.enc_int b (Op.Spawn.success_exits s);
    Bin.enc_fpath b (Op.Spawn.tool s);
    enc_cmd b (Op.Spawn.args s);
    Bin.enc_string b (Op.Spawn.stamp s);
    Bin.enc_option (Bin.enc_result ~ok:Bin.enc_string ~error:Bin.enc_string)
      b (Op.Spawn.stdo_ui s);
    Bin.enc_result ~ok:enc_os_cmd_status ~error:Bin.enc_string
      b (Op.Spawn.result s)

  let dec_spawn s i =
    let i, env = Bin.dec_list Bin.dec_string s i in
    let i, relevant_env = Bin.dec_list Bin.dec_string s i in
    let i, cwd = Bin.dec_fpath s i in
    let i, stdin = Bin.dec_option Bin.dec_fpath s i in
    let i, stdout = dec_spawn_stdo s i in
    let i, stderr = dec_spawn_stdo s i in
    let i, success_exits = Bin.dec_list Bin.dec_int s i in
    let i, tool = Bin.dec_fpath s i in
    let i, args = dec_cmd s i in
    let i, stamp = Bin.dec_string s i in
    let i, stdo_ui =
      let ok = Bin.dec_string and error = Bin.dec_string in
      Bin.dec_option (Bin.dec_result ~ok ~error) s i
    in
    let i, result =
      let ok = dec_os_cmd_status and error = Bin.dec_string in
      Bin.dec_result ~ok ~error s i
    in
    i, Op.Spawn.v ~env ~relevant_env ~cwd ~stdin ~stdout ~stderr ~success_exits
      tool args ~stamp ~stdo_ui ~result

  let enc_wait_files b wait = Bin.enc_unit b ()
  let dec_wait_files s i =
    let i, () = Bin.dec_unit s i in
    i, Op.Wait_files.v ()

  let enc_write b w =
    Bin.enc_string b (Op.Write.stamp w);
    Bin.enc_int b (Op.Write.mode w);
    Bin.enc_fpath b (Op.Write.file w);
    Bin.enc_result
      ~ok:Bin.enc_unit ~error:Bin.enc_string b (Op.Write.result w)

  let dec_write s i =
    let i, stamp = Bin.dec_string s i in
    let i, mode = Bin.dec_int s i in
    let i, file = Bin.dec_fpath s i in
    let data () = Error "Serialized op, data fun not available" in
    let i, result = Bin.dec_result ~ok:Bin.dec_unit ~error:Bin.dec_string s i in
    i, Op.Write.v ~stamp ~mode ~file ~data ~result

  let enc_kind b = function
  | Op.Copy c -> Bin.enc_byte b 0; enc_copy b c
  | Op.Delete d -> Bin.enc_byte b 1; enc_delete b d
  | Op.Mkdir m -> Bin.enc_byte b 2; enc_mkdir b m
  | Op.Read r -> Bin.enc_byte b 3; enc_read b r
  | Op.Spawn s -> Bin.enc_byte b 4; enc_spawn b s
  | Op.Wait_files w -> Bin.enc_byte b 5; enc_wait_files b w
  | Op.Write w -> Bin.enc_byte b 6; enc_write b w

  let dec_kind s i =
    let kind = "Op.kind" in
    let next, b = Bin.dec_byte ~kind s i in
    match b with
    | 0 -> let i, c = dec_copy s next in i, Op.Copy c
    | 1 -> let i, d = dec_delete s next in i, Op.Delete d
    | 2 -> let i, m = dec_mkdir s next in i, Op.Mkdir m
    | 3 -> let i, r = dec_read s next in i, Op.Read r
    | 4 -> let i, s = dec_spawn s next in i, Op.Spawn s
    | 5 -> let i, w = dec_wait_files s next in i, Op.Wait_files w
    | 6 -> let i, w = dec_write s next in i, Op.Write w
    | b -> Bin.err_byte ~kind i b

  let enc_op b o =
    Bin.enc_int b (Op.id o);
    Bin.enc_string b (Op.group o);
    enc_time_span b (Op.time_created o);
    enc_time_span b (Op.time_started o);
    enc_time_span b (Op.duration o);
    Bin.enc_bool b (Op.revived o);
    enc_status b (Op.status o);
    Bin.enc_list Bin.enc_fpath b (Op.reads o);
    Bin.enc_list Bin.enc_fpath b (Op.writes o);
    enc_hash b (Op.hash o);
    enc_kind b (Op.kind o);
    ()

  let dec_op s i =
    let i, id = Bin.dec_int s i in
    let i, group = Bin.dec_string s i in
    let i, time_created = dec_time_span s i in
    let i, time_started = dec_time_span s i in
    let i, duration = dec_time_span s i in
    let i, revived = Bin.dec_bool s i in
    let i, status = dec_status s i in
    let i, reads = Bin.dec_list Bin.dec_fpath s i in
    let i, writes = Bin.dec_list Bin.dec_fpath s i in
    let i, hash = dec_hash s i in
    let i, kind = dec_kind s i in
    i, Op.v id ~group ~time_created ~time_started ~duration ~revived
      ~status ~reads ~writes ~hash kind

  let magic = "b\x00\x00\x00"
  let list_to_string ops =
    let b = Buffer.create (1024 * 1024) in
    Bin.enc_magic b magic;
    Bin.enc_list enc_op b ops;
    Buffer.contents b

  let list_of_string ?(file = Os.File.dash) s =
    try
      let i = Bin.dec_magic s 0 magic in
      let i, ops = Bin.dec_list dec_op s i in
      Bin.dec_eoi s i;
      Ok ops
    with
    | Failure e -> Fmt.error "%a:%s" Fpath.pp_unquoted file e
end

module Exec = struct
  let pp_feedback ppf = function
  | `Exec_submit (pid, op) ->
      let pp_pid ppf = function
      | None -> () | Some pid -> Fmt.pf ppf "[pid:%d]" (Os.Cmd.pid_to_int pid)
      in
      Fmt.pf ppf "@[[SUBMIT]%a%a" pp_pid pid Op.pp_short op
end

module Memo = struct
  let pp_feedback ppf = function
  | `Fiber_exn (exn, bt) ->
      Fmt.pf ppf "@[<v>fiber exception:@,%a@]" Fmt.exn_backtrace (exn, bt)
  | `Fiber_fail e ->
      Fmt.pf ppf "@[<v>fiber failed:@,%s@]" e
  | `Miss_tool (t, e) ->
      Fmt.pf ppf "@[<v>missing tool:@,%s@]" e
  | `Op_cache_error (op, e) ->
      Fmt.pf ppf "@[op %d: cache error: %s@]" (B00.Op.id op) e
  | `Op_complete (op, fail) ->
      failwith "TODO"

  let pp_leveled_feedback
      ?(sep = Fmt.flush_nl) ?(op_howto = Fmt.nop) ~show_op_ui ~show_op ~level
      ppf f
    =
    let has_ui o = match B00.Op.kind o with
    | B00.Op.Spawn s -> Option.is_some (B00.Op.Spawn.stdo_ui s)
    | _ -> false
    in
    if level = Log.Quiet then () else
    match f with
    | `Exec_submit (_, _) -> () (* we have B0_std.Os spawn tracer on debug *)
    | `Op_complete (op, fail) ->
        if level >= Log.Debug then (Op.pp ppf op; sep ppf ()) else
        begin match (B00.Op.status op) with
        | B00.Op.Failed ->
            if level >= Log.Error
            then ((Op.pp_failed ~op_howto) ppf (op, fail); sep ppf ())
        | B00.Op.Aborted ->
            if level >= Log.Info then (Op.pp_short ppf op; sep ppf ())
        | B00.Op.Executed ->
            if level >= show_op || (level >= show_op_ui && has_ui op)
            then (Op.pp_short_with_ui ppf op; sep ppf ())
        | B00.Op.Waiting ->
              assert false
        end
    | #Memo.feedback as f ->
        if level >= Log.Error
        then (pp_feedback ppf f; sep ppf ())
    | `File_cache_need_copy _ as f ->
        if level >= Log.Warning
        then (File_cache.pp_feedback ppf f; sep ppf ())

  let pp_never_ready ~op_howto ppf fs =
    let pp_file = Fmt.(op_howto ++ Op.pp_file_write) in
    let err = match Fpath.Set.cardinal fs with
    | 1 -> "This file never became ready"
    | _ -> "These files never became ready"
    in
    Fmt.pf ppf "@[<v>[%a] %s: %a@, @[%a@]@]@."
      Fmt.(tty [`Fg `Red] string) "FAILED" err
      Fmt.(tty [`Faint] string) "(see ops reading them)"
      (Fpath.Set.pp pp_file) fs

  let pp_stats ppf m =
    let open B00 in
    let pp_op ppf (oc, ot, od) =
      Fmt.pf ppf "%a %d (%d revived)" Time.Span.pp od ot oc
    in
    let pp_op_no_cache ppf (ot, od) = Fmt.pf ppf "%a %d" Time.Span.pp od ot in
    let pp_totals ppf (ot, od) = Fmt.pf ppf "%a %d" Time.Span.pp od ot in
    let pp_xtime ppf (self, children) =
      let label = Fmt.tty_string [`Faint; `Fg `Yellow ] in
      Fmt.pf ppf "%a %a" Time.Span.pp self
        (Fmt.field ~label "children" (fun c -> c) Time.Span.pp)
        children
    in
    let pp_stime ppf cpu =
      pp_xtime ppf Time.(cpu_stime cpu, cpu_children_stime cpu)
    in
    let pp_utime ppf cpu =
      pp_xtime ppf Time.(cpu_utime cpu, cpu_children_utime cpu)
    in
    let sc, st, sd, wc, wt, wd, cc, ct, cd, rt, rd, ot, od =
      let ( ++ ) = Time.Span.add in
      let rec loop sc st sd wc wt wd cc ct cd rt rd ot od = function
      | [] -> sc, st, sd, wc, wt, wd, cc, ct, cd, rt, rd, ot, od
      | o :: os ->
          let revived = Op.revived o and d = Op.duration o in
          let ot = ot + 1 and od = od ++ d in
          match Op.kind o with
          | Op.Spawn _ ->
              let sc = if revived then sc + 1 else sc in
              loop sc (st + 1) (sd ++ d) wc wt wd cc ct cd rt rd ot od os
          | Op.Write _ ->
              let wc = if revived then wc + 1 else wc in
              loop sc st sd wc (wt + 1) (wd ++ d) cc ct cd rt rd ot od os
          | Op.Copy _ ->
              let cc = if revived then cc + 1 else cc in
              loop sc st sd wc wt wd cc (ct + 1) (cd ++ d) rt rd ot od os
          | Op.Read _ ->
              loop sc st sd wc wt wd cc ct cd (rt + 1) (rd ++ d) ot od os
          | _ ->
              loop sc st sd wc wt wd cc ct cd rt rd ot od os
      in
      loop
        0 0 Time.Span.zero 0 0 Time.Span.zero 0 0 Time.Span.zero
        0 Time.Span.zero 0 Time.Span.zero (Memo.ops m)
    in
    let ht, hd =
      let c = Memo.reviver m in
      Fpath.Map.cardinal (Reviver.file_hashes c),
      Reviver.file_hash_dur c
    in
    let dur = Time.count (Memo.clock m)in
    let cpu = Time.cpu_count (Memo.cpu_clock m) in
    (Fmt.record @@
     [ Fmt.field "spawns" (fun _ -> (sc, st, sd)) pp_op;
       Fmt.field "writes" (fun _ -> (wc, wt, wd)) pp_op;
       Fmt.field "copies" (fun _ -> (cc, ct, cd)) pp_op;
       Fmt.field "reads" (fun _ -> (rt, rd)) pp_op_no_cache;
       Fmt.field "all" (fun _ -> (ot, od)) pp_totals;
       Fmt.field "hashes" (fun _ -> (ht, hd)) pp_totals;
       Fmt.field "utime" (fun _ -> cpu) pp_utime;
       Fmt.field "stime" (fun _ -> cpu) pp_stime;
       Fmt.field "real" (fun _ -> dur) Time.Span.pp ]) ppf m
end

(*---------------------------------------------------------------------------
   Copyright (c) 2019 The b0 programmers

   Permission to use, copy, modify, and/or distribute this software for any
   purpose with or without fee is hereby granted, provided that the above
   copyright notice and this permission notice appear in all copies.

   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
   WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
   MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
   ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
   WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
   ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
   OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
  ---------------------------------------------------------------------------*)
