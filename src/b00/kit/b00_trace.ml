(*---------------------------------------------------------------------------
   Copyright (c) 2017 The b0 programmers. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open B00_std
open B00_serialk_json
open B000

let fpath p = Jsong.string (Fpath.to_string p)
let jsong_cmd c = Jsong.(list string (Cmd.to_list c))

module Trace_event = struct
  let str pp get o = Jsong.strf "%a" pp (get o)
  let span_us s =
    let span_us = Int64.(to_int @@ div (Mtime.Span.to_uint64_ns s) 1000L) in
    Jsong.int span_us

  let result ~ok = function
  | Error e -> Jsong.string e | Ok v -> Jsong.string (ok v)

  let unit_result = result ~ok:(fun () -> "ok")
  let bool_result = result ~ok:string_of_bool
  let string_result = result ~ok:(fun s -> s)
  let spawn_exit = function
  | None -> Jsong.(obj |> obj_end)
  | Some (`Exited c) -> Jsong.(obj |> mem "exited" (int c) |> obj_end)
  | Some (`Signaled c) -> Jsong.(obj |> mem "signaled" (int c) |> obj_end)

  let spawn_stdo_ui s = match Op.Spawn.stdo_ui s with
  | None -> "none"
  | Some (Ok d) -> d
  | Some (Error e) -> Fmt.str "error: %s" e

  let writes_manifest_root o obj = match Op.writes_manifest_root o with
  | None -> obj
  | Some root -> Jsong.mem "writes-manifest-root" (fpath root) obj

  let args o =
    let kind_mems obj = match Op.kind o with
    | Op.Copy c ->
        obj
        |> Jsong.mem "src" (fpath (Op.Copy.src c))
        |> Jsong.mem "dst" (fpath (Op.Copy.dst c))
        |> Jsong.mem "mode" (Jsong.strf "%o" (Op.Copy.mode c))
        |> Jsong.mem "linenum" (Jsong.(option int) (Op.Copy.linenum c))
    | Op.Delete d ->
        obj |> Jsong.mem "path" (fpath (Op.Delete.path d))
    | Op.Mkdir m ->
        obj |> Jsong.mem "dir" (fpath (Op.Mkdir.dir m))
    | Op.Notify n ->
        obj
        |> Jsong.mem "kind"
          (Jsong.string
             (B000_conv.Op.notify_kind_to_string (B000.Op.Notify.kind n)))
        |> Jsong.mem "msg" (Jsong.string (Op.Notify.msg n))
    | Op.Read r ->
        obj |> Jsong.mem "file" (fpath (Op.Read.file r))
    | Op.Spawn s ->
        let cmd = Cmd.(path (Op.Spawn.tool s) %% (Op.Spawn.args s)) in
        obj
        |> Jsong.mem "cmd" (jsong_cmd cmd)
        |> Jsong.mem "exit" (spawn_exit (Op.Spawn.exit s))
        |> Jsong.mem "cwd" (fpath (Op.Spawn.cwd s))
        |> Jsong.mem "env" (Jsong.(list string) (Op.Spawn.env s))
        |> Jsong.mem "success-exits"
          (Jsong.(list int) (Op.Spawn.success_exits s))
        |> Jsong.mem "stdo-ui" (Jsong.string (spawn_stdo_ui s))
    | Op.Wait_files _ -> obj
    | Op.Write w ->
        obj
        |> Jsong.mem "file" (fpath (Op.Write.file w))
        |> Jsong.mem "stamp" (Jsong.string (Op.Write.stamp w))
        |> Jsong.mem "mode" (Jsong.strf "%o" (Op.Write.mode w))
    in
    (* The order here is for the viewer. *)
    Jsong.obj
    |> Jsong.mem "kind" (Jsong.string (Op.kind_name (Op.kind o)))
    |> Jsong.mem "mark" (Jsong.string (Op.mark o))
    |> Jsong.mem "status"
      (Jsong.string (B000_conv.Op.status_to_string (Op.status o)))
    |> Jsong.mem "revived" (Jsong.bool (Op.revived o))
    |> Jsong.mem "writes" (Jsong.(list fpath) (Op.writes o))
    |> writes_manifest_root o
    |> Jsong.mem "time-created" (span_us (Op.time_created o))
    |> kind_mems
    |> Jsong.mem "reads" (Jsong.(list fpath) (Op.reads o))
    |> Jsong.mem "hash" (Jsong.string (Hash.to_hex (Op.hash o)))
    |> Jsong.obj_end

  let op o =
    let id o = Jsong.string (string_of_int @@ Op.id o) in
    let cat o = Jsong.string @@ Op.kind_name (Op.kind o) in
    Jsong.obj
    |> Jsong.mem "name" (id o)
    |> Jsong.mem "cat" (cat o)
    |> Jsong.mem "ph" (Jsong.string "X")
    |> Jsong.mem "ts" (span_us (Op.time_started o))
    |> Jsong.mem "dur" (span_us (Op.duration o))
    |> Jsong.mem "pid" (Jsong.int 1)
    |> Jsong.mem "tid" (Jsong.int 1)
    |> Jsong.mem "args" (args o)
    |> Jsong.obj_end

  let of_ops os = Jsong.list op os
end

module Compilation_database = struct
  let spawn_out o spawn src arr out_file =
    let cmd = Cmd.(path (Op.Spawn.tool spawn) %% (Op.Spawn.args spawn)) in
    arr |> Jsong.el begin
      Jsong.obj
      |> Jsong.mem "directory" (fpath (Op.Spawn.cwd spawn))
      |> Jsong.mem "file" (fpath src)
      |> Jsong.mem "arguments" (jsong_cmd cmd)
      |> Jsong.mem "output" (fpath out_file)
      |> Jsong.mem "id" (Jsong.int (Op.id o))
      |> Jsong.obj_end
    end

  let add_op arr o = match Op.kind o with
  | Op.Spawn s ->
      let src = match Op.reads o with [] -> Fpath.null | fs -> List.hd fs in
      List.fold_left (spawn_out o s src) arr (Op.writes o)
  | _ -> arr

  let of_ops os = Jsong.array_end (List.fold_left add_op Jsong.array os)
end

(*---------------------------------------------------------------------------
   Copyright (c) 2017 The b0 programmers

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
