(*---------------------------------------------------------------------------
   Copyright (c) 2019 The b0 programmers. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open B00_std

let hash_file (module H : Hash.T) f = match Fpath.equal f Fpath.dash with
| false -> Result.bind (H.file f) @@ fun h -> Ok (f, h)
| true -> Result.bind (Os.File.read f) @@ fun data -> Ok (f, H.string data)

let pp_hash = function
| `Short -> Fmt.using snd Hash.pp
| `Normal | `Long ->
    fun ppf (f, h) -> Hash.pp ppf h; Fmt.char ppf ' '; Fpath.pp_unquoted ppf f

let hash tty_cap log_level hash_fun format files =
  let tty_cap = B00_cli.B00_std.get_tty_cap tty_cap in
  let log_level = B00_cli.B00_std.get_log_level log_level in
  B00_cli.B00_std.setup tty_cap log_level ~log_spawns:Log.Debug;
  let hash_fun = B00_cli.Memo.get_hash_fun ~hash_fun in
  let pp_hash = pp_hash format in
  Log.if_error ~use:Cmdliner.Cmd.Exit.some_error @@ match files with
  | [] -> Ok 0
  | files ->
      let rec loop = function
      | [] -> Fmt.pr "@]"; Fmt.flush Fmt.stdout (); Ok 0
      | f :: fs ->
          match hash_file hash_fun f with
          | Ok h -> Fmt.pr "%a@," pp_hash h; loop fs
          | Error _ as e -> Fmt.pr "@]"; e
      in
      Fmt.pr "@[<v>"; loop files

(* Command line interface *)

open Cmdliner

let files =
  let doc = "File to hash. Use $(b,-) for stdin." in
  Arg.(value & pos_all B00_cli.fpath [] & info [] ~doc ~docv:"FILE")

let hash_fun =
  B00_cli.Memo.hash_fun ~opts:["H"; "hash-fun"] ~docs:Manpage.s_options ()

let tool =
  let doc = "Hash like b0" in
  let man_xrefs = [`Tool "b0"; `Tool "b00-cache"; `Tool "b00-log"] in
  let man = [
    `S Manpage.s_description;
    `P "The $(tname) command hashes files like b0 does.";
    `S Manpage.s_options;
    `S B00_cli.s_output_format_options;
    `S Manpage.s_bugs;
    `P "Report them, see $(i,%%PKG_HOMEPAGE%%) for contact information." ]
  in
  Cmd.v (Cmd.info "b00-hash" ~version:"%%VERSION%%" ~doc ~man ~man_xrefs)
    Term.(const hash $ B00_cli.B00_std.tty_cap () $
          B00_cli.B00_std.log_level () $ hash_fun $
          B00_cli.Arg.output_format () $ files)

let main () = exit (Cmd.eval' tool)
let () = if !Sys.interactive then () else main ()

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
