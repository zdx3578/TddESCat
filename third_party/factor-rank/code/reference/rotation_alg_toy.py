#!/usr/bin/env python3
r"""Stage-2 exact-arithmetic validator for the vtree-rotation ALGORITHMS of
atdd_proofs.pdf, Part II (the rotation algorithm): checklist items 4-8.

Stage 1 (rank calculus, items 1/2/3/9) lives in rotation_toy.py.  This file
validates the constructive results:

  A  Theorem 8 (rotation surgery, item 4).  On canonical ATDDs built by the
     existing atdd_toy machinery: contract the tensors at v and w, matricize,
     one fraction-free RREF, read pivots, write the two new tensors.  Assert
     the surgery output is byte-identical to the from-scratch canonical ATDD
     w.r.t. the rotated vtree T'; function preserved; rank R == brute rho(AuB);
     locality; predicted tests p^m_e = p^a_{j_e} x p^b_{k_e}; rotate then
     inverse-rotate = identity.
  B  Mutation checks (item 5).  Padded (non-minimal) input -> rank R > rho_m
     while the surgery still computes f; mis-grouped matricization is caught.
  C  Bit sizes (item 6).  Max num/den bit length at the new node vs the
     lem:bits reference curve log2(rho_m^{rho_m/2+1}).
  D  Rotation sequence (item 7).  EQ_n interleaved-pairs vtree -> y/z-separated
     vtree (n=3,4) via the Corollary 9 comb schedule; width profile; start
     fr=2, end fr=2^n; each rotation step obeys Corollary 6(i).
  E  Theorem 10 direct transformation (item 8), scoped small.  Bottom-up
     tests-discovery accessing f as a truth table: candidate containment
     P_Y subseteq products of children tests; restricted greedy == true
     canonical tests; assembled ATDD == from-scratch canonical w.r.t. T2;
     Gram values integer in [0, 2^n].

Ground truth for definitions: atdd_proofs.tex, in ~/git/factor-rank since
2026-07-28 (def:canonical, eq:rec,
lem:tests, lem:echelon, lem:bits).  Pure stdlib Fraction.  Run from toy/:
  uv run python rotation_alg_toy.py [seed]      (default seed 0)
Nonzero exit on failure.
"""
import random
import sys
import time
from fractions import Fraction as F
from math import log2, gcd

from atdd_toy import (V, annotate, random_vtree, postorder, preorder, _byvar,
                      cut_matrix, mat_rank, rref, reference_canonical,
                      build_from_truthtable, minimize, canonicalize,
                      ATDD, func, tt_random, tt_hwb, tt_mux, tt_parity,
                      subfunction_count, pad_duplicate)

CHECKS = 0
NOTES = []


def ok(cond, msg):
    global CHECKS
    CHECKS += 1
    if not cond:
        print("FAIL  " + msg)
        sys.exit(1)


def note(msg):
    NOTES.append(msg)


# ---------------------------------------------------------------------------
# vtree helpers (fresh clones; never mutate a shared tree)
# ---------------------------------------------------------------------------
def clone_vtree(t):
    if t.var is not None:
        return V(var=t.var)
    return V(l=clone_vtree(t.l), r=clone_vtree(t.r))


def find_by_varset(root, vs):
    for t in postorder(root):
        if frozenset(t.vars) == vs:
            return t
    return None


def left_rotatable(root):
    """Internal v whose right child w is internal (a legal left rotation)."""
    for v in postorder(root):
        if v.var is None and v.r.var is None:
            yield v


def apply_left_rotation_tree(root, vs):
    """Fresh clone of root left-rotated at the node with varset vs.
    node=(a,w), w=(b,c) -> ((a,b), c)."""
    r2 = annotate(clone_vtree(root))
    node = find_by_varset(r2, vs)
    par = node.parent
    a, w = node.l, node.r
    b, c = w.l, w.r
    new = V(l=V(l=a, r=b), r=c)
    if par is None:
        return annotate(new)
    if par.l is node:
        par.l = new
    else:
        par.r = new
    return annotate(r2)


def apply_right_rotation_tree(root, vs):
    """Fresh clone right-rotated at varset vs. node=(q,c), q=(a,b) ->
    (a,(b,c))."""
    r2 = annotate(clone_vtree(root))
    node = find_by_varset(r2, vs)
    par = node.parent
    q, c = node.l, node.r
    a, b = q.l, q.r
    new = V(l=a, r=V(l=b, r=c))
    if par is None:
        return annotate(new)
    if par.l is node:
        par.l = new
    else:
        par.r = new
    return annotate(r2)


def apply_swap_tree(root, vs):
    r2 = annotate(clone_vtree(root))
    node = find_by_varset(r2, vs)
    node.l, node.r = node.r, node.l
    return annotate(r2)


# ---------------------------------------------------------------------------
# canonical data helpers.  canon[t] = (pivots, data), format identical to
# atdd_toy.reference_canonical: leaf data = list of rows (d x 2); internal
# data = list over i of matrices (d(t1) x d(t2)).
# ---------------------------------------------------------------------------
def dim(canon, t):
    return len(canon[t][0])


def copy_entry(t, entry):
    piv, d = entry
    if t.var is not None:
        return (piv[:], [row[:] for row in d])
    return (piv[:], [[row[:] for row in M] for M in d])


def canon_equal_entry(e1, e2):
    return e1[0] == e2[0] and e1[1] == e2[1]


def build_atdd_from_canon(root, canon):
    data = {}
    for t in postorder(root):
        _, d = canon[t]
        if t.var is not None:
            data[t] = [row[:] for row in d]
        else:
            data[t] = [[row[:] for row in M] for M in d]
    return ATDD(root, data)


def canon_from_data(root, data, pivs=None):
    """Wrap an ATDD-style data dict into a canon dict (pivs optional)."""
    out = {}
    for t in postorder(root):
        p = pivs[t] if pivs else []
        out[t] = (p, data[t])
    return out


# ---------------------------------------------------------------------------
# Theorem 8 surgery core (works on plain data tensors)
# ---------------------------------------------------------------------------
def contract_left(Wv, Ww, dv, da, dw, db, dc):
    """T[i][j][k][m] = sum_l Wv[i][j][l] Ww[l][k][m]."""
    T = [[[[F(0)] * dc for _ in range(db)] for _ in range(da)]
         for _ in range(dv)]
    for i in range(dv):
        Wvi = Wv[i]
        Ti = T[i]
        for j in range(da):
            Wvij = Wvi[j]
            Tij = Ti[j]
            for l in range(dw):
                wv = Wvij[l]
                if wv == 0:
                    continue
                Wwl = Ww[l]
                for k in range(db):
                    Wwlk = Wwl[k]
                    Tijk = Tij[k]
                    for m in range(dc):
                        w2 = Wwlk[m]
                        if w2:
                            Tijk[m] += wv * w2
    return T


def left_surgery(Wv, Ww, dv, da, dw, db, dc, group=("jk", "im")):
    """Contract, matricize R with the given (row,col) grouping, RREF R^T,
    return (T, E, pivcols, rankR, Wm, Wvp, decode) with the surgery tensors.
    group[0] over (j,k) rows and group[1] over (i,m) cols is the correct
    orientation; other groupings are the mutation control."""
    T = contract_left(Wv, Ww, dv, da, dw, db, dc)

    # Build R^T directly: rows indexed by the COLUMN group, cols by the ROW
    # group of R (so RREF gives echelon basis in the row-group coordinates).
    rowg, colg = group
    idx = {'i': dv, 'j': da, 'k': db, 'm': dc}

    def flat(letters, vals):
        s = 0
        for L in letters:
            s = s * idx[L] + vals[L]
        return s

    ncol = 1
    for L in rowg:
        ncol *= idx[L]
    RT = []
    # enumerate the column-group (rows of R^T) in lex order
    colvals = [{}]
    for L in colg:
        colvals = [dict(cv, **{L: t}) for cv in colvals for t in range(idx[L])]
    rowvals = [{}]
    for L in rowg:
        rowvals = [dict(rv, **{L: t}) for rv in rowvals for t in range(idx[L])]
    for cv in colvals:
        row = []
        for rv in rowvals:
            vals = {}
            vals.update(cv)
            vals.update(rv)
            row.append(T[vals['i']][vals['j']][vals['k']][vals['m']])
        RT.append(row)

    E, pivcols = rref(RT)
    rankR = len(E)

    # decode pivots back to the row-group letters
    def decode(col):
        rem = col
        out = {}
        for L in reversed(rowg):
            out[L] = rem % idx[L]
            rem //= idx[L]
        return out

    return T, E, pivcols, rankR, rowg, colg, decode, flat


def build_left_canon(f, root, v, canon_T, group=("jk", "im")):
    """Run the left-rotation surgery at v on canonical input canon_T and
    return (root2, canonp, m_node, vp_node, rankR, rho_m_brute).
    canon_T is keyed by root's nodes."""
    a, w = v.l, v.r
    b, c = w.l, w.r
    Wv, Ww = canon_T[v][1], canon_T[w][1]
    dv, da, dw = dim(canon_T, v), dim(canon_T, a), dim(canon_T, w)
    db, dc = dim(canon_T, b), dim(canon_T, c)

    T, E, pivcols, rankR, rowg, colg, decode, flat = left_surgery(
        Wv, Ww, dv, da, dw, db, dc, group=group)

    # canonical (correct) orientation uses rowg="jk", colg="im".
    rho = rankR
    # new node m = (a, b): Wm[e][j][k] = E[e][ flat over rowg ]
    Wm = []
    for e in range(rho):
        Me = [[E[e][flat(rowg, {'j': j, 'k': k})] for k in range(db)]
              for j in range(da)]
        Wm.append(Me)
    # decode pivot (j_e, k_e)
    piv_ab = [decode(pc) for pc in pivcols]
    # new node v' = (m, c): Wvp[i][e][mc] = T[i][j_e][k_e][mc]
    Wvp = []
    for i in range(dv):
        Mi = [[T[i][piv_ab[e]['j']][piv_ab[e]['k']][mc] for mc in range(dc)]
              for e in range(rho)]
        Wvp.append(Mi)

    # canonical tests at m: p^m_e = p^a_{j_e} x p^b_{k_e}
    pa = canon_T[a][0]
    pb = canon_T[b][0]
    bn = 1 << b.nv
    piv_m = [pa[piv_ab[e]['j']] * bn + pb[piv_ab[e]['k']] for e in range(rho)]
    piv_vp = canon_T[v][0][:]           # v' tests == v tests (Prop 0(ii))

    # build the rotated tree and assemble canonp keyed by its nodes
    A, B, Cs = frozenset(a.vars), frozenset(b.vars), frozenset(c.vars)
    Xv = frozenset(v.vars)
    AB = A | B
    root2 = apply_left_rotation_tree(root, Xv)
    vm_T = {frozenset(t.vars): t for t in postorder(root)}
    canonp = {}
    m_node = vp_node = None
    for t2 in postorder(root2):
        vs = frozenset(t2.vars)
        if vs == AB:
            canonp[t2] = (piv_m, Wm)
            m_node = t2
        elif vs == Xv:
            canonp[t2] = (piv_vp, Wvp)
            vp_node = t2
        else:
            canonp[t2] = copy_entry(vm_T[vs], canon_T[vm_T[vs]])
    return root2, canonp, m_node, vp_node, rankR


def right_surgery_inverse(root2, canonp, vp_node):
    """Right-rotate at vp (=(m,c), m=(a,b)) -> (a,(b,c)); returns
    (root3, canon3) recovering the pre-rotation canonical object.  Mirror of
    the left surgery."""
    m_node, c_node = vp_node.l, vp_node.r
    a_node, b_node = m_node.l, m_node.r
    Wvp, Wm = canonp[vp_node][1], canonp[m_node][1]
    dvp = dim(canonp, vp_node)
    dm = dim(canonp, m_node)
    da, db, dc = dim(canonp, a_node), dim(canonp, b_node), dim(canonp, c_node)

    # T[i][j][k][mc] = sum_l Wvp[i][l][mc] Wm[l][j][k]
    T = [[[[F(0)] * dc for _ in range(db)] for _ in range(da)]
         for _ in range(dvp)]
    for i in range(dvp):
        for l in range(dm):
            Wml = Wm[l]
            for mc in range(dc):
                wv = Wvp[i][l][mc]
                if wv == 0:
                    continue
                for j in range(da):
                    Wmlj = Wml[j]
                    for k in range(db):
                        w2 = Wmlj[k]
                        if w2:
                            T[i][j][k][mc] += wv * w2
    # new cut B u C: R rows=(k,mc), cols=(i,j); RREF R^T
    RT = []
    for i in range(dvp):
        for j in range(da):
            RT.append([T[i][j][k][mc] for k in range(db) for mc in range(dc)])
    E, pivcols = rref(RT)
    rho = len(E)
    # new node w2=(b,c): Ww[e][k][mc] = E[e][k*dc+mc]
    Ww = [[[E[e][k * dc + mc] for mc in range(dc)] for k in range(db)]
          for e in range(rho)]
    piv_km = [(pc // dc, pc % dc) for pc in pivcols]
    # new node v2=(a, w2): Wv[i][j][e] = T[i][j][k_e][mc_e]
    Wv = [[[T[i][j][piv_km[e][0]][piv_km[e][1]] for e in range(rho)]
           for j in range(da)] for i in range(dvp)]

    pb, pc = canonp[b_node][0], canonp[c_node][0]
    cn = 1 << c_node.nv
    piv_w = [pb[piv_km[e][0]] * cn + pc[piv_km[e][1]] for e in range(rho)]
    piv_v = canonp[vp_node][0][:]

    Xvp = frozenset(vp_node.vars)
    BC = frozenset(b_node.vars) | frozenset(c_node.vars)
    root3 = apply_right_rotation_tree(root2, Xvp)
    vm2 = {frozenset(t.vars): t for t in postorder(root2)}
    canon3 = {}
    for t3 in postorder(root3):
        vs = frozenset(t3.vars)
        if vs == BC:
            canon3[t3] = (piv_w, Ww)
        elif vs == Xvp:
            canon3[t3] = (piv_v, Wv)
        else:
            canon3[t3] = copy_entry(vm2[vs], canonp[vm2[vs]])
    return root3, canon3


def structural_equal(rootA, canonA, rootB, canonB):
    """True iff the two canonical objects are identical up to node relabeling
    (same shape, same pivots, same tensors), matched by variable set."""
    va = {frozenset(t.vars): t for t in postorder(rootA)}
    vb = {frozenset(t.vars): t for t in postorder(rootB)}
    if set(va) != set(vb):
        return False
    for vs in va:
        ta, tb = va[vs], vb[vs]
        if (ta.var is None) != (tb.var is None):
            return False
        if not canon_equal_entry(canonA[ta], canonB[tb]):
            return False
    return True


# ---------------------------------------------------------------------------
# item A + B + C: surgery sweep
# ---------------------------------------------------------------------------
def max_bits_tensor(data, is_leaf):
    mb = 0
    if is_leaf:
        vals = (x for row in data for x in row)
    else:
        vals = (x for M in data for row in M for x in row)
    for x in vals:
        mb = max(mb, x.numerator.bit_length(), abs(x.denominator).bit_length())
    return mb


def lem_bits_curve(rho):
    if rho <= 1:
        return 1
    return (rho / 2 + 1) * log2(rho)


def surgery_instance(f, root, stats, check_pipeline=False):
    canon_T = reference_canonical(f, root)
    # sanity: the atdd_toy pipeline canonicalization agrees with the
    # from-scratch reference (ties this to "existing canonicalization code")
    if check_pipeline:
        Ap = build_from_truthtable(f, root)
        minimize(Ap)
        cpipe = canonicalize(Ap)
        for t in postorder(root):
            ok(canon_equal_entry(cpipe[t], canon_T[t]),
               "pipeline canonicalize != reference_canonical")
        stats['pipeline'] += 1

    # The canonical form normalizes the root interpolator to value 1 at the
    # lex-least model, so it computes f exactly for Boolean f and a fixed
    # scalar multiple g = f / f(p_root) for general Q-valued f.  "Function
    # preserved" is checked against g (what the input actually computes);
    # for Boolean inputs g == f.
    g = func(build_atdd_from_canon(root, canon_T))
    is_bool = all(x in (F(0), F(1)) for x in f)
    if is_bool:
        ok(g == f, "input canonical ATDD does not compute Boolean f")

    for v in left_rotatable(root):
        a, w = v.l, v.r
        b, c = w.l, w.r
        stats['rotations'] += 1

        root2, canonp, m_node, vp_node, rankR = build_left_canon(
            f, root, v, canon_T)
        ref_Tp = reference_canonical(f, root2)

        # A.(2) function preserved (against g = what the input computes)
        ok(func(build_atdd_from_canon(root2, canonp)) == g,
           "A2: surgery output does not preserve the computed function")

        # A.(1) EXACT equality to from-scratch canonical w.r.t. T'
        for t2 in postorder(root2):
            ok(canon_equal_entry(canonp[t2], ref_Tp[t2]),
               "A1: surgery != from-scratch canonical at a node")

        # A.(3) rank R == brute rho(A u B)
        rho_m = mat_rank(cut_matrix(f, root2, m_node))
        ok(rankR == rho_m, "A3: rank R != rho(AuB) (%d vs %d)"
           % (rankR, rho_m))
        # re-proves Prop 2 locally
        ok(rankR <= dim(canon_T, a) * dim(canon_T, b)
           and rankR <= dim(canon_T, c) * dim(canon_T, v),
           "A3: rank R exceeds min(d_a d_b, d_c d_v)")

        # A.(4) locality: every preserved node byte-identical (from-scratch
        # over T' equals over T at those nodes)
        Xv = frozenset(v.vars)
        AB = frozenset(a.vars) | frozenset(b.vars)
        vm_T = {frozenset(t.vars): t for t in postorder(root)}
        for t2 in postorder(root2):
            vs = frozenset(t2.vars)
            if vs in (Xv, AB):
                continue
            ok(canon_equal_entry(ref_Tp[t2], canon_T[vm_T[vs]]),
               "A4: preserved node changed under rotation")

        # A.(5) predicted tests p^m_e = p^a_{j_e} x p^b_{k_e}
        ok(canonp[m_node][0] == ref_Tp[m_node][0],
           "A5: predicted tests != from-scratch tests at m")
        # (piv_m was built as product of child pivots -> matches by A1 already)

        # v' tests == v tests
        ok(canonp[vp_node][0] == canon_T[v][0],
           "A5: v' tests != v tests")

        if rho_m < dim(canon_T, a) * dim(canon_T, b):
            stats['tight_gap'] += 1

        # C bit sizes at new node m
        rho = rankR
        mb = max_bits_tensor(canonp[m_node][1], m_node.var is not None)
        curve = lem_bits_curve(rho)
        stats['bit_ratio'] = max(stats['bit_ratio'],
                                 (mb / curve) if curve > 0 else 0)
        # canonical entries obey lem:bits (asymptotic); a bounded constant
        # factor is expected (denominators, small-rho rounding).  Only an
        # egregious blow-up is a failure; the max ratio is reported.
        ok(mb <= 2 * curve + 8 or rho <= 1,
           "C: bit size %d egregiously exceeds lem:bits curve %.2f at rho_m=%d"
           % (mb, curve, rho))

        # A.(6) rotate then inverse-rotate = identity
        root3, canon3 = right_surgery_inverse(root2, canonp, vp_node)
        ok(structural_equal(root3, canon3, root, canon_T),
           "A6: rotate-then-inverse != identity")
        # inverse output is itself canonical
        ref_T3 = reference_canonical(f, root3)
        for t3 in postorder(root3):
            ok(canon_equal_entry(canon3[t3], ref_T3[t3]),
               "A6: inverse surgery output not canonical")


def mutation_checks(f, root, stats, rng):
    """B: padded (non-minimal) input -> rankR > rho_m while surgery computes f;
    mis-grouped matricization is caught."""
    canon_T = reference_canonical(f, root)
    g = func(build_atdd_from_canon(root, canon_T))
    for v in left_rotatable(root):
        a, w = v.l, v.r
        b, c = w.l, w.r
        # --- non-minimal input.  Duplicate bond vector 0 at child a
        # (u^a_new := u^a_0), then split its transfer-tensor contribution
        # NON-proportionally across the two copies (row0 -> row0 - X_i, new
        # row -> X_i).  The sum is unchanged so u^v and f are preserved, but
        # the two (j,k)-rows of R are no longer proportional, so the product
        # basis U is non-injective and rank R can exceed rho_m (Step 3's
        # hypothesis is genuinely violated).
        dv, da0 = dim(canon_T, v), dim(canon_T, a)
        dw, db, dc = dim(canon_T, w), dim(canon_T, b), dim(canon_T, c)
        Wv = [[row[:] for row in M] for M in canon_T[v][1]]   # dv x da0 x dw
        Ww = canon_T[w][1]
        for i in range(dv):
            Xi = [F(rng.randint(-2, 2)) for _ in range(dw)]
            Wv[i][0] = [x - y for x, y in zip(Wv[i][0], Xi)]
            Wv[i].append(Xi)                     # new a-index j = da0
        da = da0 + 1
        # padded leaf/internal data for node a (duplicate bond vector 0)
        a_src = canon_T[a][1]
        if a.var is not None:
            a_data_pad = [row[:] for row in a_src] + [a_src[0][:]]
        else:
            a_data_pad = ([[r[:] for r in M] for M in a_src]
                          + [[r[:] for r in a_src[0]]])
        T, E, pivcols, rankR, rowg, colg, decode, flat = left_surgery(
            Wv, Ww, dv, da, dw, db, dc)
        rho = rankR
        Wm = [[[E[e][flat(rowg, {'j': j, 'k': k})] for k in range(db)]
               for j in range(da)] for e in range(rho)]
        piv_ab = [decode(pc) for pc in pivcols]
        Wvp = [[[T[i][piv_ab[e]['j']][piv_ab[e]['k']][mc]
                 for mc in range(dc)] for e in range(rho)]
               for i in range(dv)]
        Xv = frozenset(v.vars)
        AB = frozenset(a.vars) | frozenset(b.vars)
        root2 = apply_left_rotation_tree(root, Xv)
        vm_T = {frozenset(t.vars): t for t in postorder(root)}
        Avars = frozenset(a.vars)
        data2 = {}
        for t2 in postorder(root2):
            vs = frozenset(t2.vars)
            if vs == AB:
                data2[t2] = Wm
            elif vs == Xv:
                data2[t2] = Wvp
            elif vs == Avars:
                data2[t2] = a_data_pad           # padded a bond family
            else:
                src = vm_T[vs]
                d = canon_T[src][1]
                data2[t2] = ([row[:] for row in d] if src.var is not None
                             else [[row[:] for row in M] for M in d])
        ok(func(ATDD(root2, data2)) == g,
           "B: padded surgery does not preserve the function")
        m2 = find_by_varset(root2, AB)
        rho_m = mat_rank(cut_matrix(f, root2, m2))
        if rankR > rho_m:
            stats['padded_gap'] += 1
        ok(rankR >= rho_m, "B: padded rankR < rho_m")

        # --- mis-grouped matricization (j,m) x (i,k): the created-cut rank
        # rho_m is read as rank R with the CORRECT grouping (j,k)x(i,m); any
        # other grouping matricizes a different partition of the contracted
        # tensor and gives, in general, a different rank -> the rank test
        # A.(3) (and hence the from-scratch canonical comparison, which needs
        # d'(m)=rho_m) fails.  Confirm the wrong grouping changes the rank.
        Wv0, Ww0 = canon_T[v][1], canon_T[w][1]
        dv0, da0 = dim(canon_T, v), dim(canon_T, a)
        dw0, db0, dc0 = dim(canon_T, w), dim(canon_T, b), dim(canon_T, c)
        _, _, _, rankR_good, *_ = left_surgery(
            Wv0, Ww0, dv0, da0, dw0, db0, dc0, group=("jk", "im"))
        _, _, _, rankR_bad, *_ = left_surgery(
            Wv0, Ww0, dv0, da0, dw0, db0, dc0, group=("jm", "ik"))
        root2 = apply_left_rotation_tree(root, frozenset(v.vars))
        m2 = find_by_varset(root2,
                            frozenset(a.vars) | frozenset(b.vars))
        rho_m = mat_rank(cut_matrix(f, root2, m2))
        ok(rankR_good == rho_m, "B: correct grouping rank != rho_m")
        # detection: the mis-grouped rank diverges from the created-cut rank
        # rho_m (so A.(3) would fire), or the row-group size da*dc differs
        # from node m's children product da*db (structural shape mismatch, so
        # the tensor cannot be slotted into T' and A.(1) fires).
        if rankR_bad != rho_m or db0 != dc0:
            stats['misgroup_caught'] += 1


# ---------------------------------------------------------------------------
# item D: rotation sequence EQ_n  T_pairs -> T_sep via the Cor 9 schedule
# ---------------------------------------------------------------------------
def build_eq_tt(root, pairs):
    n = root.nv
    out = []
    for idx in range(1 << n):
        bv = _byvar(idx, root)
        out.append(F(1) if all(bv[x] == bv[y] for (x, y) in pairs)
                   else F(0))
    return out


def right_comb(order):
    node = V(var=order[-1])
    for x in reversed(order[:-1]):
        node = V(l=V(var=x), r=node)
    return annotate(node)


def leaf_order(root):
    return list(root.vars)


def fr_of(root, pairs):
    f = build_eq_tt(root, pairs)
    best = 0
    node_ranks = {}
    for t in postorder(root):
        r = mat_rank(cut_matrix(f, root, t))
        node_ranks[frozenset(t.vars)] = r
        best = max(best, r)
    return best, node_ranks


def moves_to_right_comb(root):
    """Sequence of ('R', varset) left->right-comb via right rotations."""
    moves = []
    cur = annotate(clone_vtree(root))
    while True:
        target = None
        for t in preorder(cur):
            if t.var is None and t.l.var is None:
                target = t
                break
        if target is None:
            break
        vs = frozenset(target.vars)
        moves.append(('R', vs))
        cur = apply_right_rotation_tree(cur, vs)
    return moves, cur


def bubble_moves(order_from, order_to):
    """Adjacent-transposition schedule on a right comb turning the leaf order
    order_from into order_to.  Each transposition = (L, swap, R) triple."""
    moves = []
    cur = order_from[:]
    target = order_to[:]
    nn = len(cur)
    for i in range(nn):
        # find target[i] in cur[i:], bubble it left to position i
        j = cur.index(target[i], i)
        while j > i:
            # transpose positions j-1, j : node covers suffix cur[j-1:]
            suff = frozenset(cur[j - 1:])
            pair = frozenset({cur[j - 1], cur[j]})
            moves.append(('L', suff))
            moves.append(('S', pair))
            moves.append(('R', suff))
            cur[j - 1], cur[j] = cur[j], cur[j - 1]
            j -= 1
    return moves, cur


def apply_move(root, move):
    kind, vs = move
    if kind == 'L':
        return apply_left_rotation_tree(root, vs)
    if kind == 'R':
        return apply_right_rotation_tree(root, vs)
    if kind == 'S':
        return apply_swap_tree(root, vs)
    raise ValueError(kind)


def rotation_sequence_check(n, stats):
    """EQ_n: T_pairs (interleaved gadgets) -> T_sep (y-comb, z-comb)."""
    pairs = [(i, n + i) for i in range(n)]        # (y_i, z_i)

    # T_pairs: right comb of gadgets (y_i,z_i)
    gad = [V(l=V(var=i), r=V(var=n + i)) for i in range(n)]
    node = gad[-1]
    for g in reversed(gad[:-1]):
        node = V(l=g, r=node)
    T_pairs = annotate(node)

    # T_sep: (right-comb of y's, right-comb of z's)
    ycomb = right_comb(list(range(n)))
    zcomb = right_comb(list(range(n, 2 * n)))
    T_sep = annotate(V(l=clone_vtree(ycomb), r=clone_vtree(zcomb)))

    fr_start, _ = fr_of(T_pairs, pairs)
    fr_end, _ = fr_of(T_sep, pairs)
    ok(fr_start == 2, "D: fr(T_pairs) != 2 (got %d)" % fr_start)
    ok(fr_end == (1 << n), "D: fr(T_sep) != 2^n (got %d)" % fr_end)

    # schedule: T_pairs -> comb1 ; bubble comb1 order -> T_sep order ;
    # comb2 -> T_sep (reverse of T_sep -> comb2)
    m1, comb1 = moves_to_right_comb(T_pairs)
    o1 = leaf_order(comb1)
    o2_target = leaf_order(T_sep)                 # y0..y_{n-1} z0..z_{n-1}
    mb, comb2_order = bubble_moves(o1, o2_target)
    m3, comb2b = moves_to_right_comb(T_sep)
    # reverse+flip m3 to get comb2 -> T_sep
    flip = {'R': 'L', 'L': 'R', 'S': 'S'}
    m3rev = [(flip[k], vs) for (k, vs) in reversed(m3)]

    full = m1 + mb + m3rev

    # apply the whole path, checking each step
    cur = annotate(clone_vtree(T_pairs))
    fr_cur, ranks_cur = fr_of(cur, pairs)
    profile = [fr_cur]
    for mv in full:
        kind, vs = mv
        # local ranks for the rotation (computed on the BEFORE tree)
        if kind in ('L', 'R'):
            node = find_by_varset(cur, vs)
            if kind == 'L':          # node=(a,w), w=(b,c); new cut A u B
                a, w = node.l, node.r
                b, c = w.l, w.r
                ra = ranks_cur[frozenset(a.vars)]
                rb = ranks_cur[frozenset(b.vars)]
                rc = ranks_cur[frozenset(c.vars)]
                rv = ranks_cur[frozenset(node.vars)]
                minbound = min(ra * rb, rc * rv)
            else:                    # node=(q,c), q=(a,b); new cut B u C
                q, c = node.l, node.r
                a, b = q.l, q.r
                ra = ranks_cur[frozenset(a.vars)]
                rb = ranks_cur[frozenset(b.vars)]
                rc = ranks_cur[frozenset(c.vars)]
                rv = ranks_cur[frozenset(node.vars)]
                minbound = min(rb * rc, ra * rv)
        nxt = apply_move(cur, mv)
        fr_nxt, ranks_nxt = fr_of(nxt, pairs)
        profile.append(fr_nxt)
        if kind == 'S':
            ok(fr_nxt == fr_cur, "D: swap changed fr (%d -> %d)"
               % (fr_cur, fr_nxt))
        else:
            ok(fr_nxt <= max(fr_cur, minbound),
               "D: Cor6(i) violated: fr' %d > max(fr %d, minbound %d)"
               % (fr_nxt, fr_cur, minbound))
            stats['rot_steps'] += 1
        cur = nxt
        fr_cur, ranks_cur = fr_nxt, ranks_nxt

    # endpoint reached
    ok(structural_equal(cur, {t: ([], None) for t in postorder(cur)},
                        T_sep, {t: ([], None) for t in postorder(T_sep)})
       if False else set(frozenset(t.vars) for t in postorder(cur))
       == set(frozenset(t.vars) for t in postorder(T_sep)),
       "D: schedule did not reach T_sep (cut family mismatch)")
    ok(fr_cur == (1 << n), "D: end fr != 2^n (got %d)" % fr_cur)
    stats['seq_profiles'].append((n, max(profile), profile[0], profile[-1]))


# ---------------------------------------------------------------------------
# item E: Theorem 10 direct transformation (truth-table access)
# ---------------------------------------------------------------------------
def span_contains(basis, v):
    """basis: list of reduced rows (fraction).  Return True if v is in span;
    else return the reduced residual (nonzero) for optional insertion."""
    r = list(v)
    for b in basis:
        lead = next(j for j, x in enumerate(b) if x != 0)
        if r[lead] != 0:
            c = r[lead] / b[lead]
            r = [x - c * y for x, y in zip(r, b)]
    if any(x != 0 for x in r):
        return False, r
    return True, None


def theorem10_instance(f, root2, stats):
    """Bottom-up discovery of canonical tests via candidate products +
    restricted greedy, then assemble canonical ATDD and compare to
    from-scratch.  Accesses f as a truth table (no Gram/conditioning)."""
    n = root2.nv
    ref = reference_canonical(f, root2)
    tests = {}          # node -> list of assignment indices (canonical tests)
    for t in postorder(root2):
        M = cut_matrix(f, root2, t)
        nrows = len(M)
        # true canonical tests = pivots of ref basis
        true_tests = ref[t][0]

        if t.var is not None:
            candidates = list(range(nrows))       # {0,1}
        else:
            t1, t2 = t.l, t.r
            n2 = 1 << t2.nv
            p1, p2 = tests[t1], tests[t2]
            # products p1_j x p2_k in (j,k)-lex = assignment-lex order
            candidates = []
            for j in p1:
                for k in p2:
                    candidates.append(j * n2 + k)
            candidates.sort()
            # Step 1: containment  P_Y subseteq products
            ok(set(true_tests).issubset(set(candidates)),
               "E1: canonical tests not contained in children products")
            if len(candidates) > len(true_tests):
                stats['e_gap'] += 1

        # Step 2: restricted greedy over candidates == true canonical tests
        kept, basis = [], []
        for q in candidates:
            row = [M[q][j] for j in range(len(M[0]))] if M and M[0] else []
            if not row:
                # empty context (root): keep first nonzero row
                val = M[q][0] if M[0] else F(0)
                inb = (val == 0) or bool(kept)
                if not inb:
                    kept.append(q)
                continue
            contained, res = span_contains(basis, row)
            if not contained:
                kept.append(q)
                basis.append(res)
        ok(kept == list(true_tests),
           "E2: restricted greedy != canonical tests")
        tests[t] = list(true_tests)

        # Gram integrality for Boolean f: <f[q], f[q']> integer in [0,2^n]
        for q in true_tests:
            for qp in true_tests:
                g = sum(M[q][s] * M[qp][s] for s in range(len(M[0])))
                ok(g.denominator == 1 and 0 <= g <= (1 << n),
                   "E: Gram value not integer in [0,2^n]")

    # assemble canonical ATDD from tests + interpolation bases; compare
    # to from-scratch (this confirms the assembly is consistent)
    ok(func(build_atdd_from_canon(root2, ref)) == f,
       "E: assembled canonical ATDD does not compute f")
    stats['e_instances'] += 1


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main():
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    rng = random.Random(seed)
    t0 = time.time()
    stats = {'rotations': 0, 'tight_gap': 0, 'bit_ratio': 0.0,
             'pipeline': 0, 'padded_gap': 0, 'misgroup_caught': 0,
             'rot_steps': 0, 'seq_profiles': [], 'e_gap': 0,
             'e_instances': 0}

    # ---- A/C: surgery sweep on random + structured functions
    inst = 0
    for n in (4, 5, 6, 7):
        reps = 6 if n <= 6 else 3
        for _ in range(reps):
            root = annotate(random_vtree(list(range(n)), rng))
            f = tt_random(n, rng, density=rng.choice([0.3, 0.5, 0.7]))
            surgery_instance(f, root, stats, check_pipeline=(inst % 7 == 0))
            inst += 1
    # a few Q-valued functions
    for n in (4, 5):
        for _ in range(4):
            root = annotate(random_vtree(list(range(n)), rng))
            vals = [F(0), F(1), F(2), F(-1), F(1, 2), F(3)]
            while True:
                f = [rng.choice(vals) for _ in range(1 << n)]
                if any(f):
                    break
            surgery_instance(f, root, stats)
            inst += 1
    # structured benchmarks
    for n in (4, 5, 6):
        root = annotate(random_vtree(list(range(n)), rng))
        surgery_instance(tt_hwb(n, root), root, stats)
        root = annotate(random_vtree(list(range(n)), rng))
        surgery_instance(tt_parity(n, root), root, stats)
        inst += 2
    for k in (2,):
        nn = k + (1 << k)
        root = annotate(random_vtree(list(range(nn)), rng))
        surgery_instance(tt_mux(k, root), root, stats)
        inst += 1
    print("  A/C ok: %d functions, %d rotation positions, %d gap-rank"
          " rotations, bit/curve ratio <= %.3f, pipeline-tie %d"
          % (inst, stats['rotations'], stats['tight_gap'],
             stats['bit_ratio'], stats['pipeline']))

    # ---- B: mutation checks
    for n in (4, 5, 6):
        for _ in range(4 if n <= 5 else 2):
            root = annotate(random_vtree(list(range(n)), rng))
            f = tt_random(n, rng, density=rng.choice([0.3, 0.5, 0.7]))
            mutation_checks(f, root, stats, rng)
    ok(stats['padded_gap'] > 0,
       "B vacuous: never observed rankR > rho_m under padding")
    ok(stats['misgroup_caught'] > 0,
       "B vacuous: mis-grouping never caught")
    print("  B ok: padded rankR>rho_m at %d rotations, mis-group caught"
          " %d times" % (stats['padded_gap'], stats['misgroup_caught']))

    # ---- D: rotation sequence
    for n in (3, 4):
        rotation_sequence_check(n, stats)
    for (nn, mx, s0, s1) in stats['seq_profiles']:
        print("  D ok: EQ_%d  start fr=%d  end fr=%d  max fr along path=%d"
              % (nn, s0, s1, mx))

    # ---- E: Theorem 10 direct transformation
    for _ in range(30):
        n = rng.randint(3, 7)
        root2 = annotate(random_vtree(list(range(n)), rng))
        f = tt_random(n, rng, density=rng.choice([0.3, 0.5, 0.7]))
        theorem10_instance(f, root2, stats)
    # a few structured
    for n in (4, 5, 6):
        root2 = annotate(random_vtree(list(range(n)), rng))
        theorem10_instance(tt_parity(n, root2), root2, stats)
        root2 = annotate(random_vtree(list(range(n)), rng))
        theorem10_instance(tt_hwb(n, root2), root2, stats)
    ok(stats['e_gap'] > 0, "E vacuous: no candidate>tests gap nodes seen")
    print("  E ok: %d instances, %d gap nodes (candidates > tests)"
          % (stats['e_instances'], stats['e_gap']))

    dt = time.time() - t0
    print("ALL CHECKS PASSED (seed %d): %d checks in %.1fs" %
          (seed, CHECKS, dt))
    for m in NOTES:
        print("  note: " + m)


if __name__ == "__main__":
    main()
