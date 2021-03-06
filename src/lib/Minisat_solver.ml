(* Minisat-ml, adapted from Minisat by Simon Cruanes <simon@imandra.ai>
   Copyright (c) 2019-2019, Aesthetic Integration (https://imandra.ai)
*)

(*
Copyright (c) 2003-2006, Niklas Een, Niklas Sorensson
Copyright (c) 2007-2010, Niklas Sorensson

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute,
sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
**************************************************************************************************/
 *)

open Minisat_types
open Minisat_vec.Infix

module CH = Clause.Header
module Heap = Minisat_heap.Make(Var)

(* Returns a random float 0 <= x < 1. Seed must never be 0. *)
let drand (seed: float ref) : float =
  seed := !seed *. 1389796.;
  let q = int_of_float (!seed /. 2147483647.) in
  seed := !seed -. (float_of_int q *. 2147483647.);
  !seed /. 2147483647.

let[@inline] irand (seed: float ref) (size:int) : int =
  int_of_float (drand seed *. float_of_int size)

type t = {
  mutable verbosity: int;
  mutable var_decay: float;
  mutable clause_decay : float;
  mutable random_var_freq : float;
  random_seed : float ref;
  mutable luby_restart : bool;
  mutable ccmin_mode : int; (* Controls conflict clause minimization (0=none, 1=basic, 2=deep). *)
  mutable phase_saving : int; (* Controls the level of phase saving (0=none, 1=limited, 2=full). *)
  mutable rnd_pol : bool; (* Use random polarities for branching heuristics. *)
  mutable rnd_init_act : bool;  (* Initialize variable activities with a small random value. *)
  mutable garbage_frac : float; (* The fraction of wasted memory allowed before a garbage collection is triggered. *)

  mutable restart_first : int; (* The initial restart limit. (default 100) *)
  restart_inc : float; (* The factor with which the restart limit is multiplied in each restart (default 1.5) *)
  learntsize_factor : float; (* The initial limit for learnt clauses is a factor of the original clause (default 1 / 3) *)
  learntsize_inc : float; (* The limit for learnt clauses is multiplied with this factor each restart (default 1.1) *)

  learntsize_adjust_start_confl : int;
  learntsize_adjust_inc : float;

  (* statistics: *)

  mutable solves: int;
  mutable starts: int;
  mutable decisions: int;
  mutable rnd_decisions: int;
  mutable propagations: int;
  mutable conflicts: int;
  mutable dec_vars: int;
  mutable learnt_literals: int;
  mutable clause_literals: int;
  mutable max_literals: int;
  mutable tot_literals: int;

  mutable ok: bool;

  ca: Clause.Alloc.t;
  clauses: Cref.t Vec.t; (* problem clauses *)
  learnts: Cref.t Vec.t; (* learnt clauses *)

  mutable cla_inc: float; (* Amount to bump next clause with. *)

  var_reason: Cref.t Vec.t; (* reason for the propagation of a variable *)
  var_level: int Vec.t; (* decision level of variable *)
  var_act: float Vec.t; (* A heuristic measurement of the activity of a variable. *)

  mutable var_inc: float; (* Amount to bump next variable with. *)

  (* watch list *)
  watches_cref: Cref.t Vec.t Vec.t;
  watches_blocker: Lit.t Vec.t Vec.t;
  watches_dirty: bool Vec.t;
  watches_dirties: Lit.t Vec.t;

  assigns: Lbool.t Vec.t; (* The current assignments. *)
  polarity: bool Vec.t; (* The preferred polarity of each variable. *)
  decision: bool Vec.t; (* Declares if a variable is eligible for selection in the decision heuristic. *)

  trail: Lit.t Vec.t; (* Assignment stack; stores all assigments made in the order they were made. *)
  trail_lim: int Vec.t; (* Separator indices for different decision levels in 'trail'. *)

  mutable qhead: int; (* Head of queue (as index into the trail) *)

  mutable simpDB_assigns: int; (* Number of top-level assignments since last execution of 'simplify()'. *)
  mutable simpDB_props : int; (* Remaining number of propagations that must be made before next execution of 'simplify()'. *)
  assumptions: Lit.t Vec.t; (* Current set of assumptions provided to solve by the user. *)

  order_heap: Heap.t; (* A priority queue of variables ordered with respect to the variable activity. *)

  mutable progress_estimate: float; (* Set by 'search()'. *)
  mutable remove_satisfied: bool; (* Indicates whether possibly inefficient linear scan for satisfied clauses should be performed in 'simplify'. *)

  model: Lbool.t Vec.t; (* If problem is satisfiable, this vector contains the model (if any). *)
  conflict: Lit.t Vec.t;
  (* If problem is unsatisfiable (possibly under assumptions),
     this vector represent the final conflict clause expressed in the
     assumptions. *)

  (* Temporaries (to reduce allocation overhead). Each variable is prefixed by the method in which it is
    used, except 'seen' wich is used in several places.
  *)
  seen: bool Vec.t;
  analyze_stack: Lit.t Vec.t;
  analyze_toclear: Lit.t Vec.t;
  add_tmp: Lit.t Vec.t;

  mutable max_learnts: float;
  mutable learntsize_adjust_confl : float;
  mutable learntsize_adjust_cnt : int;

  mutable conflict_budget : int; (*  -1 means no budget.*)
  mutable propagation_budget : int; (* -1 means no budget. *)
}

let set_ccmin_mode self m = assert (m >= 0 && m <= 2); self.ccmin_mode <- m

let[@inline] ok self = self.ok
let[@inline] n_vars self : int = Vec.size self.var_level
let[@inline] n_free_vars self : int =
  self.dec_vars -
  (if Vec.size self.trail_lim = 0 then Vec.size self.trail else self.trail_lim.%[ 0 ])
let[@inline] n_assigns self : int = Vec.size self.trail
let[@inline] n_clauses self : int = Vec.size self.clauses
let[@inline] n_learnts self : int = Vec.size self.learnts
let[@inline] n_starts self = self.starts
let[@inline] n_conflicts self = self.conflicts
let[@inline] n_propagations self = self.propagations
let[@inline] n_decisions self = self.decisions
let[@inline] n_rnd_decisions self = self.rnd_decisions
let[@inline] n_tot_literals self = self.tot_literals
let[@inline] n_max_literals self = self.max_literals

let[@inline] decision_level self : int = Vec.size self.trail_lim

let[@inline] activity_var self (v:Var.t) : float = self.var_act.%[ (v:>int) ]
let[@inline] set_activity_var self (v:Var.t) f : unit = self.var_act.%[ (v:>int) ] <- f

let[@inline] level_var self (v:Var.t) : int = self.var_level.%[ (v:>int) ]
let[@inline] level_lit self (x:Lit.t) : int = level_var self (Lit.var x)

let[@inline] value_var self (v:Var.t) : Lbool.t = self.assigns.%[ (v:>int) ]
let[@inline] value_lit self (x:Lit.t) : Lbool.t = Lbool.xor (value_var self (Lit.var x)) (Lit.sign x)

let[@inline] reason_var self (v:Var.t) : Cref.t = self.var_reason.%[ (v:>int) ]
let[@inline] reason_lit self (x:Lit.t) : Cref.t = reason_var self (Lit.var x)

let[@inline] abstract_level self (v:Var.t) : int =
  1 lsl (level_var self v land 31)

let set_verbosity self v =
  assert (v>=0 && v<=2);
  self.verbosity <- v

let[@inline] budget_off self : unit =
  self.conflict_budget <- -1;
  self.propagation_budget <- -1

let[@inline] within_budget self : bool =
  (self.conflict_budget < 0 || self.conflicts < self.conflict_budget) &&
  (self.propagation_budget < 0 || self.propagations < self.propagation_budget)

let add_empty_clause self = self.ok <- false

let[@inline] decision self v = self.decision.%[ (v:Var.t:>int) ]

let insert_var_order self (v:Var.t) : unit =
  if not (Heap.in_heap self.order_heap v) && decision self v then (
    Heap.insert self.order_heap v
  )

module Watch = struct
  type nonrec t = t
  let[@inline] blocker_ (self:t) (lit:Lit.t) : _ Vec.t =
    self.watches_blocker.%[ (lit:>int) ]
  let[@inline] cref_ self (lit:Lit.t) : _ Vec.t =
    self.watches_cref.%[ (lit:>int) ]

  let smudge self (lit:Lit.t) : unit =
    let i = (lit:>int) in
    if not self.watches_dirty.%[ i ] then (
      self.watches_dirty.%[ i ] <- true;
      Vec.push self.watches_dirties lit;
    )

  let init self (lit:Lit.t) : unit =
    let i = (lit:>int) in
    Vec.grow_to_with self.watches_cref (i+1) (fun _ ->Vec.make());
    Vec.grow_to_with self.watches_blocker (i+1) (fun _ ->Vec.make());
    Vec.grow_to self.watches_dirty (i+1) false;
    ()

  let clear self : unit =
    Vec.clear_dealloc self.watches_blocker;
    Vec.clear_dealloc self.watches_cref;
    Vec.clear_dealloc self.watches_dirties;
    Vec.clear_dealloc self.watches_dirty;
    ()

  let clean self (p:Lit.t) : unit =
    let p_idx = (p:>int) in
    let ws_b = self.watches_blocker.%[ p_idx ] in
    let ws_c = self.watches_cref.%[ p_idx ] in
    assert (Vec.size ws_b=Vec.size ws_c);
    let j = ref 0 in
    for i=0 to Vec.size ws_c-1 do
      let c = ws_c.%[ i ] in
      if Clause.mark self.ca c <> 1 then (
        (* not deleted, keep *)
        ws_c.%[ !j ] <- c;
        ws_b.%[ !j ] <- ws_b.%[ i ];
        j := !j + 1;
      )
    done;
    Vec.shrink ws_b !j;
    Vec.shrink ws_c !j;
    self.watches_dirty.%[ p_idx ] <- false;
    ()

  let clean_all self : unit =
    Vec.iter
      (fun (p:Lit.t) ->
         (* Dirties may contain duplicates so check here if a variable is already cleaned: *)
         if self.watches_dirty.%[ (p:>int) ] then (
           clean self p
         ))
      self.watches_dirties;
    Vec.clear self.watches_dirties
end

let set_decision_var self (v:Var.t) b : unit =
  if b && not (decision self v) then self.dec_vars <- self.dec_vars+1;
  if not b && decision self v then self.dec_vars <- self.dec_vars-1;
  self.decision.%[ (v:>int) ] <- b;
  insert_var_order self v

let new_var_ self ~polarity ~decision : Var.t =
  let v_idx = n_vars self in
  let v = Var.make v_idx in
  Watch.init self (Lit.make_sign v false);
  Watch.init self (Lit.make_sign v true);
  Vec.push self.assigns Lbool.undef;
  Vec.push self.var_level 0;
  Vec.push self.var_reason Cref.undef;
  Vec.push self.var_act
    (if self.rnd_init_act then drand self.random_seed *. 0.00001 else 0.);
  Vec.push self.seen false;
  Vec.push self.polarity polarity;
  Vec.push self.decision false;
  Vec.ensure self.trail (v_idx+1) Lit.undef;
  set_decision_var self v decision;
  v

let new_var self = new_var_ self ~polarity:true ~decision:true
let new_var' ?(polarity=true) ?(decision=true) self = new_var_ self ~polarity ~decision

let unchecked_enqueue self (p:Lit.t) (reason: Cref.t) : unit =
  assert (Lbool.equal Lbool.undef @@ value_lit self p);
  (*Printf.printf "enqueue %d (reason %d)\n" (Lit.to_int p) reason; *)
  let v_idx = (Lit.var p :> int) in
  self.assigns.%[ v_idx ] <- Lbool.of_bool (not (Lit.sign p));
  self.var_reason.%[ v_idx ] <- reason;
  self.var_level.%[ v_idx ] <- decision_level self;
  Vec.push self.trail p

let[@inline] enqueue self (p:Lit.t) (from:Cref.t) : bool =
  let v = value_lit self p in
  if Lbool.equal Lbool.undef v then (
    unchecked_enqueue self p from;
    true
  ) else (
    not (Lbool.equal Lbool.false_ v)
  )

let attach_clause (self:t) (c:Cref.t) : unit =
  (*Printf.printf "attach clause c%d:" c;
  Array.iter (fun lit -> Printf.printf " %d" (Lit.to_int lit)) (Clause.lits_a self.ca c);
  Printf.printf"\n";*)
  let h = Clause.header self.ca c in
  assert (CH.size h > 1);
  let c0 = Clause.lit self.ca c 0 in
  let c1 = Clause.lit self.ca c 1 in
  Vec.push (Watch.blocker_ self (Lit.not c0)) c1;
  Vec.push (Watch.cref_ self (Lit.not c0)) c;
  Vec.push (Watch.blocker_ self (Lit.not c1)) c0;
  Vec.push (Watch.cref_ self (Lit.not c1)) c;
  if CH.learnt h then (
    self.learnt_literals <- CH.size h + self.learnt_literals;
  ) else (
    self.clause_literals <- CH.size h + self.clause_literals;
  )

let detach_clause_ (self:t) ~strict (c:Cref.t) : unit =
  (*Printf.printf "detach clause c%d\n" c; *)
  let h = Clause.header self.ca c in
  assert (CH.size h > 1);
  let c0 = Clause.lit self.ca c 0 in
  let c1 = Clause.lit self.ca c 1 in
  if strict then (
    assert false (* NOTE: not used internally outside of Simp, and requires eager removal *)
  ) else (
    (* Lazy detaching: *)
    Watch.smudge self (Lit.not c0);
    Watch.smudge self (Lit.not c1);
  );
  if CH.learnt h then (
    self.learnt_literals <- self.learnt_literals - (CH.size h)
  ) else (
    self.clause_literals <- self.clause_literals - (CH.size h)
  )

let[@inline] detach_clause self c : unit = detach_clause_ self ~strict:false c

(* Revert to the state at given level (keeping all assignment at 'level' but not beyond). *)
let cancel_until self (level:int) : unit =
  if decision_level self > level then (
    (*Printf.printf "cancel-until %d\n" level; *)
    let offset = self.trail_lim.%[ level ] in
    for c = Vec.size self.trail-1 downto offset do
      let lit_c = self.trail.%[ c ] in
      let x = Lit.var lit_c in
      self.assigns.%[ (x:>int) ] <- Lbool.undef;
      if self.phase_saving>1 ||
         (self.phase_saving=1 && c > Vec.last self.trail_lim) then (
        (* save phase *)
        self.polarity.%[ (x:>int) ] <- Lit.sign lit_c;
      );
      insert_var_order self x;
    done;
    self.qhead <- offset;
    Vec.shrink self.trail offset;
    Vec.shrink self.trail_lim level;
  )

let pick_branch_lit self : Lit.t =
  let next =
    (* random pick? *)
    if self.random_var_freq > 0. &&
       drand self.random_seed < self.random_var_freq &&
       not (Heap.empty self.order_heap) then (
      let v = Heap.get self.order_heap
          (irand self.random_seed (Heap.size self.order_heap)) in
      if Lbool.equal Lbool.undef (value_var self v) &&
         self.decision.%[ (v:>int) ] then (
        self.rnd_decisions <- 1 + self.rnd_decisions;
      );
      v
    ) else Var.undef
  in
  let rec loop next =
    if Var.equal Var.undef next ||
       not (Lbool.equal Lbool.undef (value_var self next)) ||
       not self.decision.%[ (next:>int) ] then (

      if Heap.empty self.order_heap then Var.undef
      else loop (Heap.remove_min self.order_heap)
    ) else next
  in
  let next = loop next in
  if Var.equal Var.undef next then (
    Lit.undef
  ) else (
    Lit.make_sign next
      (if self.rnd_pol then drand self.random_seed < 0.5
       else self.polarity.%[ (next:>int) ])
  )

exception Found_watch

(* Description:
   Propagates all enqueued facts. If a conflict arises, the conflicting clause is returned,
   otherwise [Cref.undef].
   
   Post-conditions:
     * the propagation queue is empty, even if there was a conflict.
*)
let propagate (self:t) : Cref.t =
  Watch.clean_all self;
  let confl = ref Cref.undef in
  while self.qhead < Vec.size self.trail do
    let p = self.trail.%[ self.qhead ] in
    self.qhead <- self.qhead + 1;
    self.propagations <- 1 + self.propagations;
    self.simpDB_props <- self.simpDB_props - 1;

    let ws_b = self.watches_blocker.%[ (p:>int) ] in
    let ws_c = self.watches_cref.%[ (p:>int) ] in
    let n = Vec.size ws_b in
    assert (n = Vec.size ws_c);

    (* traverse watch list with index [i]. [j <= i] is position of last
       alive watch. returns j. *)
    let i=ref 0 in
    let j=ref 0 in
    while !i < n do
      let blocker = ws_b.%[ !i ] in
      let cr = ws_c.%[ !i ] in
      (*Printf.printf "  watch p=%d cr=%d\n" (p:>int) cr; *)
      if Lbool.equal Lbool.true_ (value_lit self blocker) then (
        (* avoid inspecting the clause if blocker lit is true *)
        ws_b.%[ !j ] <- blocker;
        ws_c.%[ !j ] <- cr;
        i := !i + 1;
        j := !j + 1;
      ) else (
        let ch = Clause.header self.ca cr in
        let false_lit = Lit.not p in

        (* ensure that [false_lit] is second in the clause *)
        if Lit.equal false_lit (Clause.lit self.ca cr 0) then (
          Clause.swap_lits self.ca cr 0 1;
        );
        assert (Lit.equal false_lit (Clause.lit self.ca cr 1));
        i := !i + 1;

        assert (not (Clause.reloced self.ca cr));
        let first = Clause.lit self.ca cr 0 in
        if not (Lit.equal blocker first) &&
           Lbool.equal Lbool.true_ (value_lit self first) then (
          (* If 0th watch is true, then clause is already satisfied. *)
          ws_b.%[ !j ] <- first;
          ws_c.%[ !j ] <- cr;
          j := !j + 1;
        ) else (
          (* Look for new watch: *)
          match
            for k=2 to CH.size ch-1 do
              let ck = Clause.lit self.ca cr k in
              if Lbool.equal Lbool.false_ (value_lit self ck) then (
                (* next *)
              ) else (
                (* [k]-th lit is the new watch *)
                Clause.swap_lits self.ca cr 1 k;
                Vec.push self.watches_blocker.%[ ((Lit.not ck):>int) ] first;
                Vec.push self.watches_cref.%[ ((Lit.not ck):>int) ] cr;
                raise_notrace Found_watch
              )
            done;
          with
          | exception Found_watch ->
            () (* not a watch anymore, remove from list *)
          | () ->
            (* Did not find watch -- clause is unit under assignment: *)
            ws_b.%[ !j ] <- first;
            ws_c.%[ !j ] <- cr;
            j := !j+1;
            if Lbool.equal Lbool.false_ (value_lit self first) then (
              (* conflict *)
              confl := cr;
              self.qhead <- Vec.size self.trail;
              (* Copy the remaining watches: *)
              Vec.blit ws_b !i ws_b !j (n- !i);
              Vec.blit ws_c !i ws_c !j (n- !i);
              j := !j + (n - !i);
              i := n;
            ) else (
              (* propagate [first] *)
              unchecked_enqueue self first cr;
            )
        )
      )
    done;
    Vec.shrink ws_b !j;
    Vec.shrink ws_c !j;
  done;
  !confl

let add_clause self (ps:Lit.t Vec.t) : bool =
  try
    if not self.ok then raise_notrace Early_return_false;
    assert (decision_level self = 0);
    Sort.sort_vec ~less:(fun x y -> x<y) ps;

    (* Check if clause is satisfied and remove false/duplicate literals: *)
    let j = ref 0 and p = ref Lit.undef in
    for i=0 to Vec.size ps-1 do
      let p_i = ps.%[ i ] in
      let v = value_lit self p_i in
      if Lbool.equal Lbool.true_ v || Lit.equal (Lit.not !p) p_i then (
        raise_notrace Early_return_true; (* satisfied/trivial *)
      );
      if not (Lbool.equal Lbool.false_ v) && not (Lit.equal !p p_i) then (
        (* not a duplicate *)
        ps.%[ !j ] <- p_i;
        p := p_i;
        incr j
      )
    done;
    Vec.shrink ps !j;

    if Vec.size ps = 0 then (
      self.ok <- false;
      false
    ) else if Vec.size ps = 1 then (
      unchecked_enqueue self ps.%[ 0 ] Cref.undef;
      let confl = propagate self in
      if Cref.is_undef confl then (
        true
      ) else (
        self.ok <- false;
        false
      )
    ) else (
      let cr = Clause.Alloc.alloc self.ca ps ~learnt:false in
      Vec.push self.clauses cr;
      attach_clause self cr;
      true
    )
  with
  | Early_return_true -> true
  | Early_return_false -> false

(* is the clause locked (is it the reason a literal is propagated)? *)
let locked self (c:Cref.t) : bool =
  let c0 = Clause.lit self.ca c 0 in
  Lbool.equal Lbool.true_ (value_lit self c0) &&
  c = reason_lit self c0

let remove_clause self (c:Cref.t) : unit =
  (*Printf.printf "remove clause %d\n" c; *)
  detach_clause self c;
  if locked self c then (
    self.var_reason.%[ ((Lit.var (Clause.lit self.ca c 0)):>int) ] <- Cref.undef;
  );
  Clause.set_mark self.ca c 1;
  assert (Clause.mark self.ca c = 1);
  Clause.Alloc.free self.ca c

let[@inline] new_decision_level self : unit =
  Vec.push self.trail_lim (Vec.size self.trail)

let reloc_all (self:t) ~into : unit =
  (* All watchers: *)
  (*Printf.printf "reloc all\n";*)
  Watch.clean_all self;
  for v = 0 to n_vars self -1 do
    for s = 0 to 1 do
      let p = Lit.make_sign (Var.make v) (s=1) in
      (*Printf.printf " >>> RELOCING: %s%d\n" (if Lit.sign p then "-" else "") ((Lit.var p:>int)+1);*)
      let ws_c = self.watches_cref.%[ (p:>int) ] in
      for j=0 to Vec.size ws_c-1 do
        let c = ws_c.%[ j ] in
        assert (Clause.mark self.ca c = 0); (* not deleted *)
        let c2 = Clause.reloc self.ca c ~into in
        (*Printf.printf "reloc %d into %d\n" c c2;*)
        ws_c.%[ j ] <- c2
      done;
    done;
  done;

  (* All reasons: *)
  Vec.iteri
    (fun _ lit ->
       let v = Lit.var lit in
       let r = reason_var self v in
       if not (Cref.is_undef r) && (Clause.reloced self.ca r || locked self r) then (
         let r2 = Clause.reloc self.ca r ~into in
         self.var_reason.%[ (v:>int) ] <- r2;
       ))
    self.trail;

  (* All learnt: *)
  Vec.iteri
    (fun i c -> self.learnts.%[ i ] <- Clause.reloc self.ca c ~into)
    self.learnts;

  (* All original: *)
  Vec.iteri
    (fun i c -> self.clauses.%[ i ] <- Clause.reloc self.ca c ~into)
    self.clauses;
  ()

let garbage_collect self : unit =
  (* Initialize the next region to a size corresponding to the estimated utilization degree. This
     is not precise but should avoid some unnecessary reallocations for the new region: *)
  let module CA = Clause.Alloc in
  let to_ = CA.make ~start:(CA.size self.ca - CA.wasted self.ca) () in
  reloc_all self ~into:to_;
  if self.verbosity >= 2 then (
    Printf.printf "|  Garbage collection:   %12d bytes => %12d bytes             |\n"
      (CA.size self.ca * (Sys.word_size/8)) (CA.size to_ * (Sys.word_size/8));
  );
  CA.move_to to_ ~into:self.ca;
  assert (Clause.Alloc.wasted self.ca = 0);
  ()

let check_garbage self : unit =
  if float_of_int (Clause.Alloc.wasted self.ca)
     > float_of_int (Clause.Alloc.size self.ca) *. self.garbage_frac
  then (
    garbage_collect self;
(*     Gc.major(); *)
  )

(* reduceDB : ()  ->  [void]
   
   Description:
     Remove half of the learnt clauses, minus the clauses locked by the current assignment. Locked
     clauses are clauses that are reason to some assignment. Binary clauses are never removed.
*)
let reduce_db self : unit =
  (*Printf.printf "reduce-db\n"; *)
  Sort.sort_vec
    ~less:(fun x y ->
       (*assert (Clause.learnt self.ca x);
       assert (Clause.learnt self.ca y);*)
       (* binary clauses are higher; low activity are smaller *)
       Clause.size self.ca x > 2 &&
       (Clause.size self.ca y = 2 || 
        Clause.activity self.ca x < Clause.activity self.ca y))
    self.learnts;

  let n = Vec.size self.learnts in
  (* Remove any clause below this activity *)
  let extra_lim = self.cla_inc /. float_of_int n in
  (*Printf.printf "cla-inc: %.5f  extra-lim: %.5f  learnts.size: %d\n"
    self.cla_inc extra_lim (Vec.size self.learnts);*)
  let j = ref 0 in
  for i=0 to n-1 do
    let c = self.learnts.%[ i ] in
    if Clause.size self.ca c > 2 && not (locked self c) &&
       (i < n / 2 || Clause.activity self.ca c < extra_lim) then (
      (*Printf.printf "remove clause c%d (size %d, act %.5f, cla-inc %.2f, idx %d/%d)\n"
        c (Clause.size self.ca c) (Clause.activity self.ca c) self.cla_inc i n;*)
      remove_clause self c;
    ) else (
      self.learnts.%[ !j ] <- c;
      j := !j + 1;
    )
  done;
  Vec.shrink self.learnts !j;
  check_garbage self;
  ()

let var_bump_activity self (v:Var.t) : unit =
  let a = activity_var self v +. self.var_inc in
  set_activity_var self v a;
  if a > 1e100 then (
    (* Rescale: *)
    for i=0 to n_vars self-1 do
      let v = Var.Internal.of_int i in
      set_activity_var self v (1e-100 *. activity_var self v);
    done;
    self.var_inc <- self.var_inc *. 1e-100;
  );
  (* Update order_heap with respect to new activity: *)
  if Heap.in_heap self.order_heap v then (
    Heap.decrease self.order_heap v;
  )

let cla_bump_activity self (c:Cref.t) : unit =
  let act = Clause.activity self.ca c +. self.cla_inc in
  Clause.set_activity self.ca c act;
  (*Printf.printf "set-activity c%d %.3f\n" c act;*)
  if act > 1e20 then (
    (* Rescale: *)
    for i=0 to Vec.size self.learnts-1 do
      let c = self.learnts.%[ i ] in
      Clause.set_activity self.ca c (Clause.activity self.ca c *. 1e-20);
    done;
    self.cla_inc <- self.cla_inc *. 1e-20;
  )

let[@inline] seen self (v:Var.t) : bool = self.seen.%[ (v:>int) ]
let[@inline] set_seen self (v:Var.t) b : unit = self.seen.%[ (v:>int) ] <- b

let[@inline] var_decay_activity self : unit =
  self.var_inc <- self.var_inc /. self.var_decay

let[@inline] cla_decay_activity self : unit =
  self.cla_inc <- self.cla_inc /. self.clause_decay

let lit_redundant self (p:Lit.t) (ab_lvl:int) : bool =
  (*Printf.printf "lit-redundant? %d (abs-lvl %d)\n" (Lit.to_int p) ab_lvl; *)
  Vec.clear self.analyze_stack;
  Vec.push self.analyze_stack p;
  let top = Vec.size self.analyze_toclear in
  try
    while Vec.size self.analyze_stack > 0 do
      (* clause that propagated a literal *)
      let c = reason_lit self (Vec.last self.analyze_stack) in
      Vec.pop self.analyze_stack;
      assert (not (Cref.is_undef c));
      let h = Clause.header self.ca c in

      for i=1 to CH.size h-1 do
        let p = Clause.lit self.ca c i in
        if not (seen self (Lit.var p)) && level_lit self p>0 then (
          if not (Cref.is_undef (reason_lit self p)) &&
             (abstract_level self (Lit.var p) land ab_lvl) <> 0
          then (
            set_seen self (Lit.var p) true;
            Vec.push self.analyze_stack p;
            Vec.push self.analyze_toclear p;
          ) else (
            (* cannot be eliminated, not involved in conflict.
               restore to input state + return false. *)
            for j = top to Vec.size self.analyze_toclear-1 do
              set_seen self (Lit.var self.analyze_toclear.%[ j ]) false;
            done;
            Vec.shrink self.analyze_toclear top;
            raise_notrace Early_return_false
          )
        )
      done;
    done;
    true
  with Early_return_false -> false

(* Description:
   Analyze conflict and produce a reason clause.
 
   Pre-conditions:
     * `out_learnt` is assumed to be cleared.
     * Current decision level must be greater than root level.
 
   Post-conditions:
     * `out_learnt[0]` is the asserting literal at level `out_btlevel`.
     * If out_learnt.size() > 1 then `out_learnt[1]` has the greatest decision level of the 
       rest of literals. There may be others from the same level though.
 *)
let analyze (self:t) (confl:Cref.t) (out_learnt: Lit.t Vec.t) : int =
  assert (Vec.empty out_learnt);
  (*assert (for i=0 to Vec.size self.seen-1 do assert (not (Vec.get self.seen i)) done; true); *)
  Vec.push out_learnt Lit.undef; (* leave room for asserting lit *)

  let pathC = ref 0 in
  let p = ref Lit.undef in
  let index = ref (Vec.size self.trail-1) in
  let confl = ref confl in
  let continue = ref true in

  while !continue do
    assert (not (Cref.is_undef !confl));

    let h = Clause.header self.ca !confl in
    if CH.learnt h then cla_bump_activity self !confl;

    (* resolve with the other literals of the clause *)
    for j = (if Lit.is_undef !p then 0 else 1) to CH.size h - 1 do
      let q = Clause.lit self.ca !confl j in

      if not (seen self (Lit.var q)) && level_lit self q > 0 then (
        var_bump_activity self (Lit.var q);
        set_seen self (Lit.var q) true;

        if level_lit self q >= decision_level self then (
          pathC := !pathC + 1; (* need to resolve this away *)
        ) else (
          Vec.push out_learnt q;
        )
      );
    done;

    (* next literal to consider *)
    while
      let v = Lit.var self.trail.%[ !index ] in
      index := !index -1;
      not (seen self v)
    do ()
    done;

    p := self.trail.%[ !index+1 ];
    confl := reason_lit self !p;
    set_seen self (Lit.var !p) false;
    pathC := !pathC - 1;

    (*Printf.printf "resolve-pivot: %d (pathC %d)\n" (Lit.to_int p) !pathC; *)

    if !pathC = 0 then continue := false;
  done;
  out_learnt.%[ 0 ] <- Lit.not !p;

  (* simplify conflict clause *)
  Vec.copy_to out_learnt ~into:self.analyze_toclear;
  let j = ref 0 in
  if self.ccmin_mode = 2 then (
    (* maintain an abstraction of levels involved in conflict *)
    let ab_lvl =
      let lvl = ref 0 in
      for i=1 to Vec.size out_learnt-1 do
        lvl:= !lvl lor abstract_level self (Lit.var out_learnt.%[ i ]);
      done;
      !lvl
    in

    j := 1;
    for i = 1 to Vec.size out_learnt-1 do
      let p = out_learnt.%[ i ] in
      if Cref.is_undef (reason_lit self p) || not (lit_redundant self p ab_lvl) then (
        (* decision lit, or not redundant: keep *)
        out_learnt.%[ !j ] <- p;
        j := !j + 1;
      )
    done;
  ) else if self.ccmin_mode = 1 then (
    assert false (* TODO *)
  ) else (
    j := Vec.size out_learnt;
  );

  self.max_literals <- self.max_literals + Vec.size out_learnt;
  Vec.shrink out_learnt !j;
  self.tot_literals <- self.tot_literals + Vec.size out_learnt;
  assert (Vec.size out_learnt >= 1);

  (* cleanup 'seen' *)
  Vec.iter
    (fun p -> set_seen self (Lit.var p) false)
    self.analyze_toclear;

  (*assert (for i=0 to Vec.size self.seen-1 do assert (not @@ Vec.get self.seen i) done; true);*)

  (* Find correct backtrack level: *)
  if Vec.size out_learnt = 1 then (
    0
  ) else (
    let max_i = ref 1 in
    (* Find the first literal assigned at the next-highest level: *)
    for i = 2 to Vec.size out_learnt-1 do
      if level_lit self out_learnt.%[ i ] > level_lit self out_learnt.%[ !max_i ] then (
        max_i := i;
      )
    done;
    (* Swap-in this literal at index 1: *)
    let p = out_learnt.%[ !max_i ] in
    if !max_i > 1 then (
      out_learnt.%[ !max_i ] <- out_learnt.%[ 1 ];
      out_learnt.%[ 1 ] <- p;
    );
    level_lit self p
  )

(* Description:
   Specialized analysis procedure to express the final conflict in terms of assumptions.
   Calculates the (possibly empty) set of assumptions that led to the assignment of `p`, and
   stores the result in `out_conflict`.
*)
let analyze_final self (p:Lit.t) (out_conflict: Lit.t Vec.t) : unit =
  Vec.clear out_conflict;
  Vec.push out_conflict p;

  if decision_level self > 0 then (
    set_seen self (Lit.var p) true;
    for i = Vec.size self.trail-1 downto self.trail_lim.%[ 0 ] do
      let p = self.trail.%[ i ] in
      let x = Lit.var p in
      if seen self x then (
        let c = reason_var self x in
        if Cref.is_undef c then (
          (* decision (ie assumption), push it *)
          assert (level_var self x > 0);
          Vec.push out_conflict (Lit.not p);
        ) else (
          let h = Clause.header self.ca c in
          for j=1 to CH.size h-1 do
            let vj = Lit.var (Clause.lit self.ca c j) in
            (* conflict resolution with lits that propagated [p] *)
            if level_var self vj > 0 then (
              set_seen self vj true;
            );
          done;
        );
        set_seen self x false;
      )
    done;
    set_seen self (Lit.var p) false;
  )

let satisfied self (c:Cref.t) : bool =
  Clause.exists self.ca c (fun lit -> Lbool.equal Lbool.true_ (value_lit self lit))

(* remove satisfied clauses from the given vector *)
let remove_satisfied self (cs:Cref.t Vec.t) : unit =
  let j = ref 0 in
  for i = 0 to Vec.size cs-1 do
    let c = cs.%[ i ] in
    if satisfied self c then (
      remove_clause self c
    ) else (
      cs.%[ !j ] <- c;
      j := !j + 1;
    )
  done;
  Vec.shrink cs !j

let rebuild_order_heap self : unit =
  let vs = Vec.make() in
  for v_i=0 to n_vars self-1 do
    let v = Var.Internal.of_int v_i in
    if self.decision.%[ v_i ] && Lbool.equal Lbool.undef (value_var self v)
    then Vec.push vs v
  done;
  Heap.build self.order_heap vs

let simplify self : bool =
  assert (decision_level self = 0);
  if not self.ok || not (Cref.is_undef (propagate self)) then (
    self.ok <- false;
    false
  ) else if n_assigns self = self.simpDB_assigns || self.simpDB_props > 0 then (
    true
  ) else (
    remove_satisfied self self.learnts;
    if self.remove_satisfied then (
      remove_satisfied self self.clauses;
    );
    check_garbage self;
    rebuild_order_heap self;
    self.simpDB_assigns <- n_assigns self;
    self.simpDB_props <- self.clause_literals + self.learnt_literals;
    true
  )

let progress_estimate self : float =
  let progress = ref 0. in
  let f = 1. /. float_of_int (n_vars self) in
  for i = 0 to decision_level self do
    let beg = if i=0 then 0 else self.trail_lim.%[ i-1 ] in
    let end_ = if i=decision_level self then Vec.size self.trail else self.trail_lim.%[ i ] in
    progress :=
      !progress +. (f ** (float_of_int i)) *. (float_of_int (end_ - beg));
  done;
  !progress /. (float_of_int (n_vars self))

(* search : (nof_conflicts : int) (params : const SearchParams&)  ->  [lbool]
   
   Description:
     Search for a model the specified number of conflicts. 
     NOTE! Use negative value for 'nof_conflicts' indicate infinity.
   
   Output:
     'l_True' if a partial assigment that is consistent with respect to the clauseset is found. If
     all variables are decision variables, this means that the clause set is satisfiable. 'l_False'
     if the clause set is unsatisfiable. 'l_Undef' if the bound on number of conflicts is reached.
*)
let search self (nof_conflicts:int) : Lbool.t =
  assert (self.ok);
  self.starts <- self.starts + 1;
  let learnt_clause = Vec.make() in
  let rec loop ~conflictC : Lbool.t =
    let confl = propagate self in
    if not (Cref.is_undef confl) then (
      (* conflict *)
      self.conflicts <- self.conflicts + 1;
      let conflictC = conflictC + 1 in

      if decision_level self = 0 then (
        Lbool.false_ (* toplevel conflict *)
      ) else (
        Vec.clear learnt_clause;
        let backtrack_level = analyze self confl learnt_clause in
        cancel_until self backtrack_level;
        (*Printf.printf "learnt.size %d\n" (Vec.size learnt_clause);*)

        (* propagate negation of UIP *)
        if Vec.size learnt_clause = 1 then (
          assert (backtrack_level=0);
          unchecked_enqueue self learnt_clause.%[ 0 ] Cref.undef;
        ) else (
          let c = Clause.Alloc.alloc self.ca learnt_clause ~learnt:true in
          Vec.push self.learnts c;
          attach_clause self c; (* can attach directly, 2 first lits are correct watches *)
          cla_bump_activity self c;
          unchecked_enqueue self learnt_clause.%[ 0 ] c;
        );

        var_decay_activity self;
        cla_decay_activity self;

        self.learntsize_adjust_cnt <- self.learntsize_adjust_cnt - 1;
        if self.learntsize_adjust_cnt = 0 then (
          self.learntsize_adjust_confl <-
            self.learntsize_adjust_confl *. self.learntsize_adjust_inc;
          self.learntsize_adjust_cnt <- int_of_float self.learntsize_adjust_confl;
          self.max_learnts <- self.max_learnts *. self.learntsize_inc;
          if self.verbosity >= 1 then (
            let i = int_of_float in
            Printf.printf "| %9d | %7d %8d %8d | %8d %8d %6.0f | %6.3f %% |\n%!"
              self.conflicts
              (self.dec_vars -
               (if Vec.size self.trail_lim=0 then Vec.size self.trail else self.trail_lim.%[ 0 ]))
              (n_clauses self)
              self.clause_literals
              (i self.max_learnts)
              (n_learnts self)
              (float_of_int self.learnt_literals /. float_of_int (n_learnts self))
              (progress_estimate self *. 100.);
          );

        );
        (loop[@tailcall]) ~conflictC
      )
    ) else (
      (* no conflict *)
      if (nof_conflicts >= 0 && conflictC >= nof_conflicts) ||
         not (within_budget self) then(
        self.progress_estimate <- progress_estimate self;
        cancel_until self 0;
        Lbool.undef (* give up *)
      ) else if decision_level self = 0 && not (simplify self) then (
        Lbool.false_ (* simplification => conflict *)
      ) else (
        if float_of_int (Vec.size self.learnts - n_assigns self) >= self.max_learnts then (
          (* Reduce the set of learnt clauses: *)
          reduce_db self
        );

        (* add assumptions *)
        let rec loop_add_assumps () =
          if decision_level self < Vec.size self.assumptions then (
            (* Perform user provided assumption: *)
            let p = self.assumptions.%[ decision_level self ] in
            let val_p = value_lit self p in
            if Lbool.equal Lbool.true_ val_p then (
              (* Dummy decision level *)
              new_decision_level self;
              loop_add_assumps();
            ) else if Lbool.equal Lbool.false_ val_p then (
              (* conflict with assumptions *)
              analyze_final self (Lit.not p) self.conflict;
              raise_notrace Early_return_false;
            ) else (
              (* decide p next *)
              p
            )
          ) else Lit.undef
        in
        let next = loop_add_assumps () in

        let next =
          if Lit.is_undef next then (
            (* new variable decision *)
            self.decisions <- self.decisions + 1;
            pick_branch_lit self
          ) else next 
        in

        if Lit.is_undef next then (
          Lbool.true_ (* model found *)
        ) else (
          new_decision_level self;
          (*Printf.printf "decide %d (lvl %d)\n" (Lit.to_int next) (decision_level self); *)
          unchecked_enqueue self next Cref.undef;
          (loop[@tailcall])  ~conflictC
        )
      )
    )
  in
  try loop ~conflictC:0
  with Early_return_false -> Lbool.false_

(*
  Finite subsequences of the Luby-sequence:

  0: 1
  1: 1 1 2
  2: 1 1 2 1 1 2 4
  3: 1 1 2 1 1 2 4 1 1 2 1 1 2 4 8
  ...
*)
let luby (y:float) (x:int) : float =
  (* Find the finite subsequence that contains index 'x', and the
     size of that subsequence: *)
  let rec luby_loop1 ~size ~seq =
    if size >= x+1 then size,seq
    else (
      let seq = seq + 1 in
      let size = 2*size + 1 in
      luby_loop1 ~size ~seq
    )
  in
  let size, seq = luby_loop1 ~size:1 ~seq:0 in
  let rec luby_loop2 ~x ~size ~seq =
    if size-1 = x then seq
    else (
      let size = (size-1) lsr 1 in
      let seq = seq -1 in
      let x = x mod size in
      luby_loop2 ~x ~size ~seq
    )
  in
  let seq = luby_loop2 ~x ~size ~seq in
  y ** float_of_int seq

let solve_ (self:t) : Lbool.t =
  Vec.clear self.model;
  Vec.clear self.conflict;
  if not self.ok then (
    Lbool.false_
  ) else (
    self.solves <- self.solves + 1;
    self.max_learnts <- float_of_int (n_clauses self) *. self.learntsize_factor;
    self.learntsize_adjust_confl <- float_of_int self.learntsize_adjust_start_confl;
    self.learntsize_adjust_cnt <- int_of_float self.learntsize_adjust_confl;

    if self.verbosity >= 1 then (
      Printf.printf "============================[ Search Statistics ]==============================\n";
      Printf.printf "| Conflicts |          ORIGINAL         |          LEARNT          | Progress |\n";
      Printf.printf "|           |    Vars  Clauses Literals |    Limit  Clauses Lit/Cl |          |\n";
      Printf.printf "===============================================================================\n%!";
    );

    (* search until budget is exhausted, or status is true/false *)
    let rec loop_search ~curr_restarts =
      let rest_base =
        if self.luby_restart then luby self.restart_inc curr_restarts
        else self.restart_inc ** (float_of_int curr_restarts)
      in
      let status = search self (int_of_float (rest_base *. float_of_int self.restart_first)) in
      if not (within_budget self) then status (* break *)
      else if Lbool.equal Lbool.undef status
      then loop_search ~curr_restarts:(curr_restarts+1)
      else status
    in
    let status = loop_search ~curr_restarts:0 in

    if self.verbosity >= 1 then (
      Printf.printf("===============================================================================\n%!");
    );

    if Lbool.equal Lbool.true_ status then (
      (* extend and copy model *)
      Vec.grow_to self.model (n_vars self) Lbool.undef;
      for i=0 to n_vars self-1 do
        self.model.%[ i ] <- value_var self (Var.Internal.of_int i)
      done
    ) else if Lbool.equal Lbool.false_ status && Vec.size self.conflict = 0 then (
      (* empty clause, no assumptions involved *)
      self.ok <- false;
    );

    cancel_until self 0;
    status
  )

let solve self ~assumps : bool =
  budget_off self;
  Vec.copy_to assumps ~into:self.assumptions;
  Lbool.equal Lbool.true_ (solve_ self)

let solve_limited (self:t) ~assumps : Lbool.t =
  Vec.copy_to assumps ~into:self.assumptions;
  solve_ self

let create(): t =
  let var_act = Vec.make () in
  (* heap of variables, ordered by activity (higher activity comes first) *)
  let order_heap =
    Heap.make
      ~less:(fun v1 v2 -> var_act.%[ (v1:>int) ] > var_act.%[ (v2:>int) ])
  in
  let s = {
    verbosity=0;
    var_decay=0.95;
    clause_decay=0.999;
    random_var_freq=0.;
    random_seed=ref 91648253.;
    luby_restart=true;
    ccmin_mode=2;
    phase_saving=2;
    rnd_pol=false;
    rnd_init_act=false;
    garbage_frac=0.20;
    restart_first=100;
    restart_inc=2.;
    learntsize_factor=(1./.3.);
    learntsize_inc=1.1;
    learntsize_adjust_start_confl=100;
    learntsize_adjust_inc=1.5;
    solves=0;
    starts=0;
    decisions=0;
    rnd_decisions=0;
    propagations=0;
    conflicts=0;
    dec_vars=0;
    clause_literals=0;
    learnt_literals=0;
    max_literals=0;
    tot_literals=0;

    ok=true;

    ca=Clause.Alloc.make ();
    clauses=Vec.make();
    learnts=Vec.make();
    cla_inc=1.;

    var_reason=Vec.make();
    var_level=Vec.make();
    var_act;
    var_inc=1.;

    watches_cref=Vec.make();
    watches_blocker=Vec.make();
    watches_dirty=Vec.make();
    watches_dirties=Vec.make();

    assigns=Vec.make();
    polarity=Vec.make();
    decision=Vec.make();

    trail=Vec.make();
    trail_lim=Vec.make();
    qhead=0;
    simpDB_assigns= -1;
    simpDB_props=0;
    assumptions=Vec.make();

    progress_estimate= 0.;
    remove_satisfied=true;

    model=Vec.make();
    conflict=Vec.make();
    seen=Vec.make();
    analyze_stack=Vec.make();
    analyze_toclear=Vec.make();
    add_tmp=Vec.make();
    order_heap;
    max_learnts=0.;
    learntsize_adjust_confl=0.;
    learntsize_adjust_cnt =0;
    conflict_budget= -1;
    propagation_budget= -1;
  } in
  s
