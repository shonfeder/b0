(*---------------------------------------------------------------------------
   Copyright (c) 2018 The b0 programmers. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open B00_std
open B00_std.Result.Syntax

open Cmdliner

(* Environment variables *)

module Env = struct
  let visual = "VISUAL"
  let editor = "EDITOR"
end

let envs =
  let vars = lazy begin
    Cmd.Env.info Env.visual
      ~doc:"The editor used to edit files. This is a command invocation given \
            to execvp(3) and is used before EDITOR." ::
    Cmd.Env.info Env.editor
      ~doc:"The editor used to edit files. This is a command invocation given \
            to execvp(3) and is used after VISUAL." ::
    []
  end
  in
  fun () -> Lazy.force vars

(* Editing *)

let find ?win_exe ?search () =
  let parse_env cmds env = match cmds with
  | Error _ as e -> e
  | Ok cmds as r ->
      let empty_is_none = true in
      match Os.Env.find' ~empty_is_none B00_std.Cmd.of_string env with
      | Error _ as e -> e
      | Ok None -> r
      | Ok (Some cmd) -> Ok (cmd :: cmds)
  in
  let cmds = Ok [B00_std.Cmd.atom "nano"] in
  let cmds = parse_env cmds Env.editor in
  let* cmds = parse_env cmds Env.visual in
  let rec loop = function
  | [] -> Ok None
  | cmd :: cmds ->
      match Os.Cmd.find ?win_exe ?search cmd with
      | Ok None -> loop cmds
      | v -> v
  in
  loop cmds

let edit_files editor fs = match editor with
| None -> Error "No runnable editor found in VISUAL or EDITOR"
| Some editor -> Os.Cmd.run_status B00_std.Cmd.(editor %% paths fs)

(*---------------------------------------------------------------------------
   Copyright (c) 2018 The b0 programmers

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
