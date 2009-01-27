(* Filesystem Interface to Git.
 * Copyright (C) 2008 Reilly Grant
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 *)

open Repository
open Manager
open Object
open Unix
open Unix.LargeFile

let root_commit = ref ""

let base_stat = {
  st_dev = 0;
  st_ino = 0;
  st_kind = Unix.S_REG;
  st_perm = 0o644;
  st_nlink = 1;
  st_uid = Unix.getuid ();
  st_gid = Unix.getgid ();
  st_rdev = 0;
  st_size = 0L;
  st_atime = Unix.time ();
  st_mtime = Unix.time ();
  st_ctime = Unix.time ()
}

let figfs_getattr (path:string) : Unix.LargeFile.stats =
  if path = "/"
  then { base_stat with
         st_kind = Unix.S_DIR;
         st_perm = 0o755 }
  else try (
    let dir = traverse_tree !root_commit (Filename.dirname path) in
    match dir with
    | Tree t ->
      let (perms,_,file_hash) =
        List.find (fun (_,n,_) -> n = (Filename.basename path)) t.t_dirents in
      let file_stat = stat_object file_hash in
      let kind =
        match file_stat.os_type with
        | TTree -> Unix.S_DIR
        | TBlob -> Unix.S_REG
        | _ -> failwith "Getattr of commit?" in
      { base_stat with
        st_kind = kind;
        st_perm = if file_stat.os_type = TBlob then perms else 0o755;
        st_size = Int64.of_int file_stat.os_size }
    | _ -> failwith "Parent object not directory?"
  ) with Not_found -> raise (Unix.Unix_error (Unix.ENOENT, "getattr", path))

let figfs_readdir (path:string) (fd:int) : string list =
  let entries =
    try
      let dir = traverse_tree !root_commit path in
      match dir with
      | Tree t -> List.map (fun (_,n,_) -> n) t.t_dirents
      | _ -> raise (Unix.Unix_error (Unix.ENOTDIR, "readdir", path))
    with Not_found -> raise (Unix.Unix_error (Unix.ENOENT, "readdir", path))
  in "." :: ".." :: entries

(* Copies the contents of the given string into the given buffer, returning
 * the number of bytes copied. *)
let string_to_buffer_blit (str:string) (start:int) (len:int) (buf:Fuse.buffer)
    : int =
  for i = start to (start + len - 1) do
    Bigarray.Array1.set buf (i - start) (String.get str i)
  done;
  len

let figfs_read (path:string) (buf:Fuse.buffer) (off:int64) (fd:int) : int =
  let offset = Int64.to_int off in
  try
    let file = traverse_tree !root_commit path in
    match file with
    | Blob b ->
      if offset < 0 || offset >= (String.length b.b_data)
      then raise (Unix.Unix_error (Unix.EINVAL, "read", path))
      else
        let to_read =
          min (String.length b.b_data - offset) (Bigarray.Array1.dim buf) in
        string_to_buffer_blit b.b_data offset to_read buf
    | _ -> raise (Unix.Unix_error (Unix.EISDIR, "read", path))
  with Not_found -> raise (Unix.Unix_error (Unix.ENOENT, "read", path))

let figfs_readlink (path:string) : string =
  try
    let file = traverse_tree !root_commit path in
    match file with
    | Blob b -> b.b_data
    | _ -> raise (Unix.Unix_error (Unix.EINVAL, "readlink", path))
  with Not_found -> raise (Unix.Unix_error (Unix.ENOENT, "readlink", path))

let operations : Fuse.operations = {
  Fuse.default_operations with
  Fuse.getattr = figfs_getattr;
  Fuse.readdir = figfs_readdir;
  Fuse.read = figfs_read;
  Fuse.readlink = figfs_readlink
}

let make_absolute path =
  let slash_index =
    try String.index path '/'
    with Not_found -> -1 in
  if slash_index <> 0
  then Printf.sprintf "%s/%s" (Sys.getcwd ()) path
  else path

let repo_dir = ref (find_repo ())

let fuse_opts = ref []

let argspec =
  [("-r", Arg.String (fun s -> repo_dir := Some (make_absolute s)),
      "repository path");
     ("-c", Arg.Set_string root_commit,
      "root commit");
     ("-d", Arg.Unit (fun () -> fuse_opts := "-d" :: !fuse_opts),
      "debug output (implies -f)");
     ("-f", Arg.Unit (fun () -> fuse_opts := "-f" :: !fuse_opts),
      "foreground operation");
     ("-s", Arg.Unit (fun () -> fuse_opts := "-s" :: !fuse_opts),
      "disable-multithreaded operation");
     ("-o", Arg.String (fun s ->
       fuse_opts := Printf.sprintf "-o %s" s :: !fuse_opts),
      "Fuse options.")]

let argrest s =
  fuse_opts := s :: !fuse_opts

let argusage = "usage: figfs [options] mountpoint"

let _ =
  Arg.parse argspec argrest argusage;
  match !repo_dir with
  | Some dir -> (
      set_repo_dir dir;
      let args = Array.of_list ("figfs" :: List.rev !fuse_opts) in
      Fuse.main args operations
    )
  | None -> Printf.eprintf "No repository found.\n"
