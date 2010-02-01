
open Unix
open LargeFile
open Bigarray
open Fuse

open Lwt
open Printf
open Git
open Git_types


(* lwt would sprinkle this module with monads everywhere, nip it in the bud. *)
let wait_on_monad monad =
  (* let waiter, wakener = Lwt.wait () in *)
  (* XXX Lwt_main.run not thread-safe. Or just not reentrant, which is OK. *)
  Lwt_main.run monad

(* Going through the shell is evil/ugly,
 * but I didn't find a non system()-based api *)
(* Unlike a shell backtick, doesn't remove trailing newlines *)
let backtick shell_cmd =
  prerr_endline (Printf.sprintf "Command “%S”" shell_cmd);
  let out_pipe = BatUnix.open_process_in shell_cmd in
  BatIO.read_all out_pipe

let trim_endline str =
  (* XXX not what the spec says, this trims both ends *)
  BatString.trim str

let git_wt = "/home/g2p/var/co/git/ocaml-git" (* XXX *)
let git_dir = git_wt ^ "/.git"

let repo = wait_on_monad (Git.Repo.repo git_wt)

let backtick_git cmd =
  let cmd_str = String.concat " " ("git"::"--git-dir"::git_dir::cmd) in
  backtick cmd_str

let dir_stats = LargeFile.stat "." (* XXX *)
let file_stats = { dir_stats with
  st_nlink = 1;
  st_kind = S_REG;
  st_perm = 0o400;
  (* /proc uses zero, it works. /sys uses 4k. *)
  st_size = Int64.zero;
  }
let symlink_stats = { file_stats with
  st_kind = S_LNK;
  }

let fname = "hello"
let name = "/" ^ fname
let contents : Fuse.buffer = Array1.of_array Bigarray.char Bigarray.c_layout
  [|'H';'e';'l';'l';'o';' ';'w';'o';'r';'l';'d';'!'|]


type hash = string

type scaff_assoc = (string * scaffolding) list
and scaff_assoc_io = unit -> scaff_assoc
and scaffolding =
  |RootScaff
  |TreesScaff
  |RefsScaff
  |RefScaff of string
  |Symlink of string
  |FileHash of hash
  |TreeHash of hash
  |CommitHash of hash
  |CommitMsg of hash
  |OtherHash of hash (* gitlink, etc *)


(* association list for the fs root *)
let root_al = [
  "trees", TreesScaff;
  "refs", RefsScaff;
  (*"commits", CommitsScaff;*)
  ]

let slash_free s =
  (*prerr_endline (Printf.sprintf "Encoding “%S”" s);*)
  (* urlencode as soon as I find a module that implements it *)
  (* Str.global_replace (Str.regexp_string "/") "-" s *)
  BatBase64.str_encode s

let reslash s =
  let r = BatBase64.str_decode s in
  (*prerr_endline (Printf.sprintf "Decoding into “%S”" r);*)
  r

let commit_of_ref ref =
  (*
  let opts = `BoolOpt ("hash", true) :: `BoolOpt ("verify", true) :: `Bare ref
  :: [] in
  let stdout s = s in
  wait_on_monad (repo#git#exec ~stdout "show-ref" opts);
  *)
  trim_endline (backtick_git [ "show-ref"; "--hash"; "--verify"; "--"; ref ])

let tree_of_commit hash =
  trim_endline (backtick_git [ "rev-parse"; "--revs-only"; "--no-flags";
  "--verify"; "--quiet"; hash ^ "^{tree}" ])

let rec parents_depth depth =
  if depth = 0 then ""
  else "../" ^ parents_depth (depth - 1)

let commit_symlink_of_ref ref depth =
  let to_root = parents_depth depth in
  Symlink (to_root ^ "commits/" ^ (commit_of_ref ref))

let tree_symlink_of_commit hash depth =
  let to_root = parents_depth depth in
  Symlink (to_root ^ "trees/" ^ (tree_of_commit hash))

let depth_of_scaff = function
  |RootScaff -> 0
  |RefScaff _ -> 2
  |CommitHash _ -> 2
  |_ -> failwith "not implemented"

let scaffolding_child scaff child =
  match scaff with
  |RootScaff -> List.assoc child root_al
  |TreesScaff -> raise Not_found (* XXX *)
  |RefsScaff -> let ref = reslash child in RefScaff ref
  |FileHash _ -> raise Not_found
  |TreeHash _ -> raise Not_found (* XXX *)
  |RefScaff name ->
    if child = "current" then commit_symlink_of_ref name (depth_of_scaff scaff)
    (*else if child = "reflog" then ReflogScaff name*)
    else raise Not_found
  |CommitHash hash ->
    if child = "msg" then CommitMsg hash
    else if child = "worktree" then tree_symlink_of_commit hash (depth_of_scaff
    scaff)
    (*else if child = "parents" then CommitParents hash*)
    else raise Not_found
  |CommitMsg _ -> raise Not_found
  |Symlink _ -> raise Not_found
  |OtherHash _ -> raise Not_found

let list_children = function
  |RootScaff -> List.map fst root_al
  |TreesScaff -> [] (* XXX *)
  |RefsScaff -> let heads = wait_on_monad (repo#heads ()) in
   List.map (fun (n, h) -> slash_free (trim_endline n)) heads
  |RefScaff name -> [ "current"; (*"reflog";*) ]
  |TreeHash _ -> [] (* XXX *)
  |CommitHash _ -> [] (* XXX *)
  |FileHash _ -> raise Not_found
  |OtherHash _ -> raise Not_found
  |CommitMsg _ -> raise Not_found
  |Symlink _ -> raise Not_found

let is_container = function
  |RootScaff -> true
  |TreesScaff -> true
  |RefsScaff -> true
  |TreeHash _ -> true
  |CommitHash _ -> true
  |RefScaff _ -> true

  |FileHash _ -> false
  |OtherHash _ -> false
  |CommitMsg _ -> false
  |Symlink _ -> false


let lookup scaff path =
  let rec lookup_r scaff = function
    |[] -> scaff
    |dir::rest ->
	lookup_r (scaffolding_child scaff dir) rest
  in match BatString.nsplit path "/" with
  |""::""::[] -> lookup_r scaff []
  |""::path_comps ->
      lookup_r scaff path_comps
  |_ -> assert false (* fuse path must start with a slash *)



let fh_data = Hashtbl.create 16
let fh_by_name = Hashtbl.create 16

let next_fh = ref 0

let lookup_and_cache path =
  try
    Hashtbl.find fh_by_name path
  with Not_found ->
    let scaff = lookup RootScaff path in
    let fh = !next_fh in
    incr next_fh;
    Hashtbl.add fh_by_name path (fh, scaff);
    Hashtbl.add fh_data fh scaff;
    (fh, scaff)

let lookup_fh fh =
  Hashtbl.find fh_data fh



let do_getattr path =
  try
   let scaff = lookup RootScaff path in
   (*if is_container scaff
    then dir_stats
    else file_stats*)
   match scaff with
   |RootScaff -> dir_stats
   |TreesScaff -> dir_stats
   |RefsScaff -> dir_stats
   |TreeHash _ -> dir_stats
   |CommitHash _ -> dir_stats
   |RefScaff _ -> dir_stats
   |FileHash _ -> file_stats
   |OtherHash _ -> file_stats
   |CommitMsg _ -> file_stats
   |Symlink _ -> symlink_stats
   with Not_found ->
    raise (Unix_error (ENOENT, "stat", path))

let do_opendir path flags =
  (*prerr_endline ("Path is: " ^ path);*)
  try
    let fh, scaff = lookup_and_cache path in
    Some fh
  with Not_found ->
    raise (Unix_error (ENOENT, "opendir", path))

let do_readdir path fh =
  try
    let scaff = lookup_fh fh in
    "."::".."::(list_children scaff)
  with Not_found ->
    assert false (* because opendir passed *)
    (*raise (Unix_error (ENOENT, "readdir", path))*)

let do_readlink path =
  try
   let scaff = lookup RootScaff path in
   match scaff with
   |Symlink target -> target
   |_ -> raise (Unix_error (EINVAL, "readlink (not a link)", path))
   with Not_found ->
    raise (Unix_error (ENOENT, "readlink", path))


let do_fopen path flags =
  if path = name then None
  else raise (Unix_error (ENOENT, "open", path))

let do_read path buf ofs fh =
  if path = name then
    if ofs > (Int64.of_int max_int) then 0
    else
      let ofs = Int64.to_int ofs in
      let len = min ((Array1.dim contents) - ofs) (Array1.dim buf) in
	(Array1.blit (Array1.sub contents ofs len) (Array1.sub buf 0 len);
	 len)
  else raise (Unix_error (ENOENT, "read", path))

let _ =
  main Sys.argv
    {
      default_operations with
	getattr = do_getattr;
	opendir = do_opendir;
	readdir = do_readdir;
	readlink = do_readlink;
	fopen = do_fopen;
	read = do_read;
    }
