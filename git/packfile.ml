(* Git pack file access.
 * Copyright (C) 2009 Reilly Grant
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
open Object
open Hash
open Util

let pack_directory () : string =
  List.fold_left Filename.concat (get_repo_dir ()) ["objects"; "pack"]

let enumerate_packs () : string list =
  let files = Sys.readdir (pack_directory ()) in
  let indicies = List.filter (fun f -> (String.length f = 49) &&
    starts_with "pack-" f && ends_with ".idx" f) (Array.to_list files) in
  List.map (fun s -> String.sub s 5 40) indicies

let index_path (pack:string) : string =
  if String.length pack <> 40
  then failwith "Invalid pack name (must be 40 character hash)."
  else (
    let name = Printf.sprintf "pack-%s.idx" pack in
    Filename.concat (pack_directory ()) name
  )

let pack_path (pack:string) : string =
  if String.length pack <> 40
  then failwith "Invalid pack name (must be 40 character hash)."
  else (
    let name = Printf.sprintf "pack-%s.pack" pack in
    Filename.concat (pack_directory ()) name
  )

(* Read the fanout table.  Expects fd to point to the beginning of the table.
 * After completion fd points to the first byte after the table.  Returns
 * the range in the index table to search and the number of objects in the
 * pack. *)
let read_fanout (fd:Unix.file_descr) (fanout:int) : int * int * int =
  let buf = String.create 4 in
  let startpos =
    if fanout <> 0
    then (
      ignore (Unix.lseek fd ((fanout - 1) * 4) Unix.SEEK_CUR);
      ignore (Unix.read fd buf 0 4);
      decode_int buf
    ) else 0 in
  ignore (Unix.read fd buf 0 4);
  let endpos = decode_int buf in
  ignore (Unix.lseek fd ((255 - fanout - 1) * 4) Unix.SEEK_CUR);
  ignore (Unix.read fd buf 0 4);
  let length = decode_int buf in
  (startpos, endpos, length)

let scan_indexv1 (fd:Unix.file_descr) (hash:hash) : int64 =
  let buf = String.create 24 in
  let binhash = base256_of_base16 hash in
  (* index fanout table is keyed on the first byte of the hash *)
  let fanout = int_of_char (String.get binhash 0) in
  let startpos, endpos, size = read_fanout fd fanout in
  ignore (Unix.lseek fd (startpos * 24) Unix.SEEK_CUR);
  let rec loop pos =
    if pos >= endpos
    then raise Not_found
    else (
      ignore (Unix.read fd buf 0 24);
      if (String.sub buf 4 20) = binhash
      then decode_int32 (String.sub buf 0 4)
      else loop (pos + 1)
    ) in
  Int64.of_int32 (loop startpos)

let scan_indexv2 (fd:Unix.file_descr) (hash:hash) : int64 =
  let buf = String.create 20 in
  ignore (Unix.read fd buf 0 4);
  let version = decode_int32 buf in
  if version <> 2l then failwith "Expected index version 2."
  else (
    let binhash = base256_of_base16 hash in
    let fanout = int_of_char (String.get binhash 0) in
    let startpos, endpos, size = read_fanout fd fanout in
    ignore (Unix.lseek fd (startpos * 20) Unix.SEEK_CUR);
    let rec loop pos =
      if pos >= endpos
      then raise Not_found
      else (
        ignore (Unix.read fd buf 0 20);
        if buf = binhash
        then pos
        else loop (pos + 1)
      ) in
    let pos = loop startpos in
    (* need to move (size - pos - 1) * 20 + size * 4 + pos * 4 *)
    let shift = (size - pos - 1) * 20 + size * 4 + pos * 4 in
    ignore (Unix.lseek fd shift Unix.SEEK_CUR);
    ignore (Unix.read fd buf 0 4);
    let offset = decode_int32 buf in
    if Int32.logand offset 0x80000000l <> 0l
    then (
      (* need to move (size - pos - 1) * 4 + offset * 8 *)
      let shift = (size - pos - 1) * 4 +
          (Int32.to_int offset land 0x7fffffff) * 8 in
      ignore (Unix.lseek fd shift Unix.SEEK_CUR);
      ignore (Unix.read fd buf 0 8);
      decode_int64 buf
    ) else Int64.of_int32 offset
  )

let scan_index (pack:string) (hash:hash) : int64 =
  let fd = Unix.openfile (index_path pack) [Unix.O_RDONLY] 0 in
  let buf = String.create 4 in
  ignore (Unix.read fd buf 0 4);
  let offset = try (
    if buf = "\xfftOc"
    then scan_indexv2 fd hash
    else (
      ignore (Unix.lseek fd 0 Unix.SEEK_SET);
      scan_indexv1 fd hash
    )
  ) with e -> Unix.close fd; raise e in
  Unix.close fd;
  offset

(* Unpack a simply compressed object. Expects fd to be seeked to the beginning
 * of the compressed data. *)
let unpack_compressed_object (stat:obj_stat) (fd:Unix.file_descr)
    : obj_stat * string =
   stat, inflate_file fd

(* Read an object from the pack, expects fd to already be seeked to offset. *)
let rec unpack_object (hash:hash) (offset:int64) (fd:Unix.file_descr)
    : obj_stat * string =
  (* Read the object header from the pack. *)
  let buf = String.create 80 in
  ignore (Unix.read fd buf 0 80);
  let header = int_of_varint buf in
  (* The object type is stored as bits 7 to 5 of the size... weird *)
  let int_type = (header lsr 4) land 0x7 in
  let typ = obj_type_of_int int_type in
  let size = ((header lsr 3) land (lnot 0xf)) lor (header land 0xf) in
  let stat = { os_hash = hash; os_type = typ; os_size = size } in
  (* Seek to the beginning of the data. *)
  let data_pos = index_with buf is_seven_bit + 1 in
  let data_offset = Int64.add offset (Int64.of_int data_pos) in
  ignore (Unix.LargeFile.lseek fd data_offset Unix.SEEK_SET);
  match typ with
  | TCommit | TTree | TBlob | TTag -> unpack_compressed_object stat fd
  | TOfsDelta -> unpack_ofs_delta_object offset stat fd
  | TRefDelta -> unpack_ref_delta_object stat fd

(* Unpack an offset delta object. Expects fd to be seeked to the beginning of
 * the offset data. *)
and unpack_ofs_delta_object (offset:int64) (stat:obj_stat) (fd:Unix.file_descr)
   : obj_stat * string =
  let offset_buf = String.create 20 in
  ignore (Unix.read fd offset_buf 0 20);
  let base_offset =
    Int64.sub offset (Int64.of_int (int_of_offsetint offset_buf)) in
  let data_pos = index_with offset_buf is_seven_bit + 1 - 20 in
  ignore (Unix.LargeFile.lseek fd (Int64.of_int data_pos) Unix.SEEK_CUR);
  let patch = inflate_file fd in
  ignore (Unix.LargeFile.lseek fd base_offset Unix.SEEK_SET);
  let base_stat, base =
    unpack_object "0000000000000000000000000000000000000000" base_offset fd in
  let data = Delta.patch base patch in
  { stat with
    os_size = String.length data;
    os_type = base_stat.os_type }, data

(* Unpack a reference delta object. Expects fd to be seeked to the beginning of
 * the referenced object's hash. *)
and unpack_ref_delta_object (stat:obj_stat) (fd:Unix.file_descr)
   : obj_stat * string =
  let base_hash = String.create 20 in
  ignore (Unix.read fd base_hash 0 20);
  let base_stat, base = find_object_raw (base16_of_base256 base_hash) in
  let patch = inflate_file fd in
  let data = Delta.patch base patch in
  { stat with
    os_size = String.length data;
    os_type = base_stat.os_type }, data

and find_object_raw_in_pack (pack:string) (hash:hash) : obj_stat * string =
  (* Get the object offset from the index. *)
  let offset = scan_index pack hash in
  (* Seek to the object. *)
  let fd = Unix.openfile (pack_path pack) [Unix.O_RDONLY] 0 in
  ignore (Unix.LargeFile.lseek fd offset Unix.SEEK_SET);
  let objekt =
    try unpack_object hash offset fd
    with e -> Unix.close fd; raise e in
  Unix.close fd;
  objekt

and find_object_raw (hash:hash) : obj_stat * string =
  let packs = enumerate_packs () in
  let data = List.fold_left (fun data pack ->
    try (
      if (data = None)
      then Some (find_object_raw_in_pack pack hash)
      else data
    ) with Not_found -> None) None packs in
  match data with
  | Some data ->
      (* print_endline (String.escaped (snd data)); *)
      data
  | None -> raise Not_found

let stat_object (hash:hash) : obj_stat =
  let stat, _ = find_object_raw hash in
  stat

let find_object (hash:hash) : obj =
  let stat, data = find_object_raw hash in
  parse_obj hash stat.os_type data
