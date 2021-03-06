(*
  This file is part of the "OCamlFuse" library.

  OCamlFuse is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation (version 2 of the License).
  
  OCamlFuse is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.
  
  You should have received a copy of the GNU General Public License
  along with OCamlFuse.  See the file LICENSE.  If you haven't received
  a copy of the GNU General Public License, write to:
  
  Free Software Foundation, Inc.,
  59 Temple Place, Suite 330, Boston, MA
  02111-1307  USA

  Vincenzo Ciancia

  applejack@users.sf.net
  vincenzo_ml@yahoo.it
*)

open Fuse_lib

type buffer = (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

type context = Fuse_bindings.__fuse_context

let get_context : unit -> context = Fuse_bindings.fuse_get_context

type xattr_flags = AUTO | CREATE | REPLACE

type statfs = 
    { 
      f_bsize : int64;
      f_blocks : int64;
      f_bfree : int64;
      f_bavail : int64;
      f_files : int64;
      f_ffree : int64;
      f_namelen : int64;
    }

type operations =
    {
      getattr : string -> Unix.LargeFile.stats;
      readlink : string -> string;
      readdir : string -> int -> string list;
      opendir : string -> Unix.open_flag list -> int option;
      releasedir : string -> Unix.open_flag list -> int -> unit;
      fsyncdir : string -> bool -> int -> unit; 
      mknod : string -> int -> unit;
      mkdir : string -> int -> unit;
      unlink : string -> unit;
      rmdir : string -> unit;
      symlink : string -> string -> unit;
      rename : string -> string -> unit;
      link : string -> string -> unit;
      chmod : string -> int -> unit;
      chown : string -> int -> int -> unit;
      truncate : string -> int64 -> unit; 
      utime : string -> float -> float -> unit;
      fopen : string -> Unix.open_flag list -> int option;
      read : string -> buffer -> int64 -> int -> int;
      write : string -> buffer -> int64 -> int -> int;
      release : string -> Unix.open_flag list -> int -> unit;
      flush : string -> int -> unit;
      statfs : string -> statfs;
      fsync : string -> bool -> int -> unit; 
      listxattr : string -> string list;      
      getxattr : string -> string -> string;
      setxattr : string -> string -> string -> xattr_flags -> unit;
      removexattr : string -> string -> unit;
    }

let op_names_of_operations ops =
  {
      Fuse_bindings.getattr = Fuse_lib.named_op ops.getattr;
      Fuse_bindings.readlink = Fuse_lib.named_op ops.readlink;
      Fuse_bindings.readdir = Fuse_lib.named_op_2 ops.readdir;
      Fuse_bindings.opendir = Fuse_lib.named_op_2 ops.opendir;
      Fuse_bindings.releasedir = Fuse_lib.named_op_3 ops.releasedir;
      Fuse_bindings.fsyncdir = Fuse_lib.named_op_3 ops.fsyncdir;
      Fuse_bindings.mknod = Fuse_lib.named_op_2 ops.mknod;
      Fuse_bindings.mkdir = Fuse_lib.named_op_2 ops.mkdir;
      Fuse_bindings.unlink = Fuse_lib.named_op ops.unlink;
      Fuse_bindings.rmdir = Fuse_lib.named_op ops.rmdir;
      Fuse_bindings.symlink = Fuse_lib.named_op_2 ops.symlink;
      Fuse_bindings.rename = Fuse_lib.named_op_2 ops.rename;
      Fuse_bindings.link = Fuse_lib.named_op_2 ops.link;
      Fuse_bindings.chmod = Fuse_lib.named_op_2 ops.chmod;
      Fuse_bindings.chown = Fuse_lib.named_op_3 ops.chown;
      Fuse_bindings.truncate = Fuse_lib.named_op_2 ops.truncate;
      Fuse_bindings.utime = Fuse_lib.named_op_3 ops.utime;
      Fuse_bindings.fopen = Fuse_lib.named_op_2 ops.fopen;
      Fuse_bindings.read = Fuse_lib.named_op_4 ops.read;
      Fuse_bindings.write = Fuse_lib.named_op_4 ops.write;
      Fuse_bindings.release = Fuse_lib.named_op_3 ops.release;
      Fuse_bindings.flush = Fuse_lib.named_op_2 ops.flush;
      Fuse_bindings.statfs = Fuse_lib.named_op ops.statfs;
      Fuse_bindings.fsync = Fuse_lib.named_op_3 ops.fsync;
      Fuse_bindings.listxattr = Fuse_lib.named_op 
				  (fun path ->
				     let s = ops.listxattr path in 
				       (s,List.fold_left 
					  (fun acc s -> 
					     acc + 1 + (String.length s)) 
					  0 s));
      Fuse_bindings.getxattr = Fuse_lib.named_op_2 ops.getxattr;
      Fuse_bindings.setxattr = Fuse_lib.named_op_4 ops.setxattr;
      Fuse_bindings.removexattr = Fuse_lib.named_op_2 ops.removexattr;
  }

let default_operations = 
  {
    getattr = undefined;
    readdir = undefined;
    opendir = undefined;
    releasedir = undefined;
    fsyncdir = undefined;
    readlink = undefined;
    mknod = undefined;
    mkdir = undefined;
    unlink = undefined;
    rmdir = undefined;
    symlink = undefined;
    rename = undefined;
    link = undefined;
    chmod = undefined;
    chown = undefined;
    truncate = undefined;
    utime = undefined;
    fopen = undefined;
    read = undefined;
    write = undefined;
    flush = undefined;
    release = undefined;
    statfs = undefined;
    fsync = undefined;
    listxattr = undefined;
    getxattr = undefined;
    setxattr = undefined;
    removexattr = undefined; 
  }

let main argv ops =
  Fuse_bindings.ml_fuse_init ();
  Fuse_bindings.set_fuse_operations (op_names_of_operations ops);
  Fuse_bindings.ml_fuse_main argv (Fuse_bindings.get_fuse_operations ())
