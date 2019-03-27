
open Minisat_ml

type t

val make : in_channel -> t

val parse_int : t -> int

val skip_whitespace : t -> unit

val skip_line : t -> unit

val skip_metadata : t -> unit
(** Skip header, comments, etc. *)

val read_int_list : t -> int list
(** Read a clause as an integer list, for debug purpose *)

val read_int_list_list : t -> int list list
(** Read all clauses as integer lists, for debug purpose *)

(* TODO
val read_clause : t -> Solver.t -> Vec_lit.t -> unit

val parse_dimacs : t -> Solver.t -> unit
   *)

(* NOTE: we can't really do gzip without a lot of trouble around IO channels *)