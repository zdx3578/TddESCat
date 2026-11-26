#!/usr/bin/env python3
"""Toy validator for ATDD canonicalization (lex-RREF gauge).

Validates, with exact rational arithmetic (stdlib Fraction) and brute-force
truth-table oracles, the claims of atdd_note.tex plus the canonicity programme:

  V1  Realization: minimal bond dimensions == cut ranks (all nodes at once).
  V2  Sandwich: rho_t <= S_t <= 2^rho_t - 1.
  V3  Lex-RREF canonical form: network-side minimize+canonicalize is
      gauge/padding-invariant, equals the brute-force reference canonical
      form exactly (pivots and all tensor entries), and is idempotent.
  V4  HWB bond dims <= n+2, MUX <= n, PARITY == 2, clause <= 2, on random vtrees.
  V5  Apply pipeline: conjunction = Hadamard product, minimize+canonicalize
      after each step; function stays correct; canonical entries stay within
      the Hadamard minor bound ~ (rho/2) log2 rho bits.
  V6  Operations: model count via ones-contraction; EQ via sum (f-g)^2 = 0;
      Boolean promise check via sum (f^2-f)^2 = 0 (cross-inner products).

Pure stdlib. Run:  uv run python atdd_toy.py
"""
from fractions import Fraction as F
import random
import sys
import time

# ----------------------------------------------------------------------
# exact linear algebra over Fraction (matrices = list of row lists)
# ----------------------------------------------------------------------

def mat_mul(A, B):
    n, m, p = len(A), len(B), len(B[0])
    assert len(A[0]) == m
    out = [[F(0)] * p for _ in range(n)]
    for i in range(n):
        Ai, oi = A[i], out[i]
        for k in range(m):
            a = Ai[k]
            if a:
                Bk = B[k]
                for j in range(p):
                    if Bk[j]:
                        oi[j] += a * Bk[j]
    return out

def mat_T(A):
    return [list(col) for col in zip(*A)]

def mat_eye(n):
    return [[F(1) if i == j else F(0) for j in range(n)] for i in range(n)]

def rref(M):
    """Reduced row echelon form. Returns (R, pivot_cols). M not modified."""
    R = [row[:] for row in M]
    rows = len(R)
    cols = len(R[0]) if rows else 0
    piv = []
    r = 0
    for c in range(cols):
        sel = next((i for i in range(r, rows) if R[i][c] != 0), None)
        if sel is None:
            continue
        R[r], R[sel] = R[sel], R[r]
        inv = F(1) / R[r][c]
        R[r] = [x * inv for x in R[r]]
        for i in range(rows):
            if i != r and R[i][c] != 0:
                f = R[i][c]
                R[i] = [x - f * y for x, y in zip(R[i], R[r])]
        piv.append(c)
        r += 1
        if r == rows:
            break
    return R[:r], piv

def mat_rank(M):
    if not M or not M[0]:
        return 0
    return len(rref(M)[0])

def mat_inv(A):
    n = len(A)
    Aug = [A[i][:] + [F(1) if j == i else F(0) for j in range(n)] for i in range(n)]
    R, piv = rref(Aug)
    assert len(R) == n and piv == list(range(n)), "matrix not invertible"
    return [row[n:] for row in R]

# ----------------------------------------------------------------------
# vtrees
# ----------------------------------------------------------------------

class V:
    """vtree node. Leaves carry a variable id (int). Ordered children."""
    __slots__ = ('var', 'l', 'r', 'vars', 'nv', 'off', 'parent', 'is_left')
    def __init__(self, var=None, l=None, r=None):
        self.var, self.l, self.r = var, l, r
        self.parent = None
        self.is_left = None

def annotate(root):
    def sizes(t):
        if t.var is not None:
            t.vars = [t.var]; t.nv = 1
        else:
            sizes(t.l); sizes(t.r)
            t.vars = t.l.vars + t.r.vars
            t.nv = t.l.nv + t.r.nv
    sizes(root)
    def offs(t, off):
        t.off = off
        if t.var is None:
            t.l.parent = t; t.l.is_left = True
            t.r.parent = t; t.r.is_left = False
            offs(t.l, off)
            offs(t.r, off + t.l.nv)
    offs(root, 0)
    root.parent = None
    return root

def random_vtree(varlist, rng):
    if len(varlist) == 1:
        return V(var=varlist[0])
    k = rng.randint(1, len(varlist) - 1)
    return V(l=random_vtree(varlist[:k], rng), r=random_vtree(varlist[k:], rng))

def postorder(t):
    out = []
    def go(x):
        if x.var is None:
            go(x.l); go(x.r)
        out.append(x)
    go(t)
    return out

def preorder(t):
    out = []
    def go(x):
        out.append(x)
        if x.var is None:
            go(x.l); go(x.r)
    go(t)
    return out

# ----------------------------------------------------------------------
# ATDD data structure
#   leaf t: rows [val_at_x=0, val_at_x=1]            (r_t x 2)
#   internal t: list (i) of matrices (r_t1 x r_t2)
# Local assignment index at t: left-subtree bits more significant:
#   idx(tau1 x tau2) = idx(tau1) * 2^{nv(t2)} + idx(tau2). This equals lex
#   order on assignments in vtree leaf order with 0 < 1.
# ----------------------------------------------------------------------

class ATDD:
    def __init__(self, root, data):
        self.root = root
        self.data = data
    def dim(self, t):
        return len(self.data[t])
    def copy(self):
        d = {}
        for t, x in self.data.items():
            if t.var is not None:
                d[t] = [row[:] for row in x]
            else:
                d[t] = [[row[:] for row in M] for M in x]
        return ATDD(self.root, d)

def vecs(A, t):
    """Brute force: explicit truth tables of the bond functions at t."""
    if t.var is not None:
        return [row[:] for row in A.data[t]]
    U1 = vecs(A, t.l); U2 = vecs(A, t.r)
    n2 = 1 << t.r.nv
    out = []
    for Wi in A.data[t]:
        v = [F(0)] * (1 << t.nv)
        for j, u1 in enumerate(U1):
            for k, u2 in enumerate(U2):
                c = Wi[j][k]
                if c:
                    for a, x in enumerate(u1):
                        if x:
                            base = a * n2
                            cx = c * x
                            for b, y in enumerate(u2):
                                if y:
                                    v[base + b] += cx * y
        out.append(v)
    return out

def func(A):
    return vecs(A, A.root)[0]

# ---- network-side recursions (all polynomial in network size) ---------

def gram(A, t, partial=None):
    """G[i][i'] = sum over assignments of X_t consistent with `partial`
    (dict var->bit) of u_i u_i'."""
    if t.var is not None:
        L = A.data[t]
        r = len(L)
        if partial and t.var in partial:
            b = partial[t.var]
            return [[L[i][b] * L[j][b] for j in range(r)] for i in range(r)]
        return [[L[i][0] * L[j][0] + L[i][1] * L[j][1] for j in range(r)]
                for i in range(r)]
    G1 = gram(A, t.l, partial)
    G2 = gram(A, t.r, partial)
    W = A.data[t]
    r = len(W)
    Bs = [mat_mul(mat_mul(G1, Wi), G2) for Wi in W]
    G = [[F(0)] * r for _ in range(r)]
    for i in range(r):
        Bi = Bs[i]
        for ip in range(i, r):
            Wip = W[ip]
            s = F(0)
            for a in range(len(Wip)):
                ra, rb = Wip[a], Bi[a]
                for b in range(len(ra)):
                    if ra[b] and rb[b]:
                        s += ra[b] * rb[b]
            G[i][ip] = s; G[ip][i] = s
    return G

def cross_inner(A, B, t=None):
    """X[i][j] = sum_tau u^A_i(tau) u^B_j(tau) for bond functions at t."""
    if t is None:
        t = A.root
    if t.var is not None:
        La, Lb = A.data[t], B.data[t]
        return [[La[i][0] * Lb[j][0] + La[i][1] * Lb[j][1]
                 for j in range(len(Lb))] for i in range(len(La))]
    X1 = cross_inner(A, B, t.l)
    X2 = cross_inner(A, B, t.r)
    WA, WB = A.data[t], B.data[t]
    out = []
    for Wa in WA:
        Y = mat_mul(mat_mul(mat_T(X1), Wa), X2)   # (r1B x r2B)
        row = []
        for Wb in WB:
            s = F(0)
            for a in range(len(Wb)):
                ra, rb = Wb[a], Y[a]
                for b in range(len(ra)):
                    if ra[b] and rb[b]:
                        s += ra[b] * rb[b]
            row.append(s)
        out.append(row)
    return out

def point_eval(A, t, assign):
    if t.var is not None:
        b = assign[t.var]
        return [row[b] for row in A.data[t]]
    e1 = point_eval(A, t.l, assign)
    e2 = point_eval(A, t.r, assign)
    out = []
    for Wi in A.data[t]:
        s = F(0)
        for j, a in enumerate(e1):
            if a:
                rowj = Wi[j]
                for k, b in enumerate(e2):
                    if b and rowj[k]:
                        s += a * rowj[k] * b
        out.append(s)
    return out

def ones_contract(A, t):
    if t.var is not None:
        return [row[0] + row[1] for row in A.data[t]]
    s1 = ones_contract(A, t.l)
    s2 = ones_contract(A, t.r)
    out = []
    for Wi in A.data[t]:
        s = F(0)
        for j, a in enumerate(s1):
            if a:
                rowj = Wi[j]
                for k, b in enumerate(s2):
                    if b and rowj[k]:
                        s += a * rowj[k] * b
        out.append(s)
    return out

def model_count(A):
    return ones_contract(A, A.root)[0]

# ---- combination networks ---------------------------------------------

def hadamard(A, B):
    """Pointwise product network (conjunction for Boolean inputs)."""
    assert A.root is B.root
    d = {}
    for t in preorder(A.root):
        if t.var is not None:
            d[t] = [[ra[0] * rb[0], ra[1] * rb[1]]
                    for ra in A.data[t] for rb in B.data[t]]
        else:
            r1a, r1b = len(A.data[t.l]), len(B.data[t.l])
            r2a, r2b = len(A.data[t.r]), len(B.data[t.r])
            mats = []
            for Wa in A.data[t]:
                for Wb in B.data[t]:
                    M = [[F(0)] * (r2a * r2b) for _ in range(r1a * r1b)]
                    for j1 in range(r1a):
                        Wa1 = Wa[j1]
                        for k1 in range(r2a):
                            c1 = Wa1[k1]
                            if not c1:
                                continue
                            for j2 in range(r1b):
                                Wb2 = Wb[j2]
                                Mrow = M[j1 * r1b + j2]
                                for k2 in range(r2b):
                                    if Wb2[k2]:
                                        Mrow[k1 * r2b + k2] = c1 * Wb2[k2]
                    mats.append(M)
            d[t] = mats
    return ATDD(A.root, d)

def equal_funcs(A, B):
    """sum (f-g)^2 == 0, via three cross-inner contractions."""
    aa = cross_inner(A, A)[0][0]
    ab = cross_inner(A, B)[0][0]
    bb = cross_inner(B, B)[0][0]
    return aa - 2 * ab + bb == 0

def is_boolean(A):
    """Promise check: sum (f^2-f)^2 == 0. Minimizes the square first to keep
    contraction dimensions small."""
    P = hadamard(A, A)
    minimize(P)
    return equal_funcs(P, A)

# ----------------------------------------------------------------------
# brute-force oracle
# ----------------------------------------------------------------------

def cut_matrix(f, root, t):
    n, nT, nP = root.nv, t.nv, t.off
    nS = n - nT - nP
    M = [[F(0)] * (1 << (nP + nS)) for _ in range(1 << nT)]
    for ip in range(1 << nP):
        for itau in range(1 << nT):
            base = (ip << (nT + nS)) | (itau << nS)
            row = M[itau]
            for isuf in range(1 << nS):
                row[(ip << nS) | isuf] = f[base | isuf]
    return M

def subfunction_count(M):
    seen = set()
    for row in M:
        tpl = tuple(row)
        if any(x != 0 for x in tpl):
            seen.add(tpl)
    return len(seen)

def ref_subspace_basis(f, root, t):
    """Lex-RREF basis of V_t = span of columns of M_t (functions of tau)."""
    M = cut_matrix(f, root, t)
    gens = set()
    for j in range(len(M[0])):
        col = tuple(M[i][j] for i in range(len(M)))
        if any(x != 0 for x in col):
            gens.add(col)
    R, piv = rref([list(g) for g in sorted(gens)])
    return R, piv

def reference_canonical(f, root):
    basis = {t: ref_subspace_basis(f, root, t) for t in postorder(root)}
    ref = {}
    for t in postorder(root):
        E, piv = basis[t]
        if t.var is not None:
            ref[t] = (piv, [row[:] for row in E])
        else:
            E1, p1 = basis[t.l]
            E2, p2 = basis[t.r]
            n2 = 1 << t.r.nv
            tensor = [[[E[i][cj * n2 + ck] for ck in p2] for cj in p1]
                      for i in range(len(E))]
            ref[t] = (piv, tensor)
    return ref

def brute_ranks(f, root):
    return {t: mat_rank(cut_matrix(f, root, t)) for t in postorder(root)}

def build_from_truthtable(f, root):
    """Prop 4.1(ii) construction with lex-RREF bases (already canonical)."""
    ref = reference_canonical(f, root)
    data = {t: d for t, (_, d) in ref.items()}
    return ATDD(root, {t: ([r[:] for r in d] if t.var is not None
                           else [[row[:] for row in M] for M in d])
                       for t, d in data.items()})

# ----------------------------------------------------------------------
# gauges and paddings
# ----------------------------------------------------------------------

def random_invertible(n, rng):
    Lm, Um = mat_eye(n), mat_eye(n)
    for i in range(n):
        for j in range(i):
            Lm[i][j] = F(rng.randint(-2, 2))
            Um[j][i] = F(rng.randint(-2, 2))
    P = mat_eye(n)
    rng.shuffle(P)
    return mat_mul(mat_mul(Lm, Um), P)

def apply_node_transform(A, t, T, D):
    """Node-t rows become T * (old rows); parent slot folded with D, where
    semantically u_old = D * u_new (exact gauges) or D = Lambda^T (phase 2)."""
    if t.var is not None:
        old = A.data[t]
        A.data[t] = [[sum(T[a][j] * old[j][b] for j in range(len(old)))
                      for b in (0, 1)] for a in range(len(T))]
    else:
        old = A.data[t]
        r1, r2 = len(old[0]), len(old[0][0])
        new = []
        for a in range(len(T)):
            M = [[F(0)] * r2 for _ in range(r1)]
            for j in range(len(old)):
                c = T[a][j]
                if c:
                    Wj = old[j]
                    for x in range(r1):
                        Mx, Wx = M[x], Wj[x]
                        for y in range(r2):
                            if Wx[y]:
                                Mx[y] += c * Wx[y]
            new.append(M)
        A.data[t] = new
    p = t.parent
    if p is None:
        return
    A.data[p] = [mat_mul(mat_T(D), Wi) if t.is_left else mat_mul(Wi, D)
                 for Wi in A.data[p]]

def random_gauge(A, rng):
    for t in postorder(A.root):
        if t is A.root or A.dim(t) == 0:
            continue
        R = random_invertible(A.dim(t), rng)
        apply_node_transform(A, t, R, mat_inv(R))

def pad_duplicate(A, t, rng):
    if t is A.root:
        return
    r = A.dim(t)
    j = rng.randrange(r)
    alpha = F(rng.randint(1, 3), rng.randint(4, 6))
    if t.var is not None:
        A.data[t] = A.data[t] + [A.data[t][j][:]]
    else:
        A.data[t] = A.data[t] + [[row[:] for row in A.data[t][j]]]
    p = t.parent
    newW = []
    for Wi in A.data[p]:
        if t.is_left:
            M = [row[:] for row in Wi] + [[alpha * x for x in Wi[j]]]
            M[j] = [(1 - alpha) * x for x in M[j]]
        else:
            M = [row[:] + [alpha * row[j]] for row in Wi]
            for row in M:
                row[j] = (1 - alpha) * row[j]
        newW.append(M)
    A.data[p] = newW

def pad_dead(A, t, rng):
    if t is A.root:
        return
    if t.var is not None:
        A.data[t] = A.data[t] + [[F(rng.randint(0, 2)), F(rng.randint(0, 2))]]
    else:
        r1, r2 = len(A.data[t][0]), len(A.data[t][0][0])
        A.data[t] = A.data[t] + [[[F(rng.randint(-1, 1)) for _ in range(r2)]
                                  for _ in range(r1)]]
    p = t.parent
    newW = []
    for Wi in A.data[p]:
        if t.is_left:
            newW.append([row[:] for row in Wi] + [[F(0)] * len(Wi[0])])
        else:
            newW.append([row[:] + [F(0)] for row in Wi])
    A.data[p] = newW

def messy(A0, rng, n_pads=3):
    A = A0.copy()
    nodes = [t for t in postorder(A.root) if t is not A.root]
    for _ in range(n_pads):
        t = rng.choice(nodes)
        (pad_duplicate if rng.random() < 0.5 else pad_dead)(A, t, rng)
    random_gauge(A, rng)
    return A

# ----------------------------------------------------------------------
# minimization
# ----------------------------------------------------------------------

MIN_STATS = {"p1": 0, "p2": 0}

def minimize(A):
    """Phase 1 (bottom-up): drop Gram-kernel redundancy so bond families are
    linearly independent. Phase 2 (top-down): restrict each bond to the
    context-relevant subspace K = colspace(H). Preserves the function;
    afterwards r_t = rank of the cut matrix at every t."""
    # ---- phase 1
    for t in postorder(A.root):
        if t is A.root:
            continue
        G = gram(A, t)
        r = len(G)
        _, kept = rref(G)          # PSD: pivot columns = independent subset
        if len(kept) < r:
            MIN_STATS["p1"] += 1
            T = [[F(1) if j == kept[a] else F(0) for j in range(r)]
                 for a in range(len(kept))]
            D = [[F(0)] * len(kept) for _ in range(r)]
            for a, j in enumerate(kept):
                D[j][a] = F(1)
            Gs = [[G[a][b] for b in kept] for a in kept]
            Gs_inv = mat_inv(Gs)
            for d in range(r):
                if d in kept:
                    continue
                rhs = [G[k][d] for k in kept]
                gamma = [sum(Gs_inv[i][j] * rhs[j] for j in range(len(rhs)))
                         for i in range(len(rhs))]
                res = G[d][d] - sum(gamma[x] * rhs[x] for x in range(len(rhs)))
                assert res == 0, "phase-1 residual nonzero (theory violation!)"
                for a in range(len(kept)):
                    D[d][a] = gamma[a]
            apply_node_transform(A, t, T, D)
    # ---- phase 2 (fresh H-chain per node: stale-proof)
    for t in preorder(A.root):
        if t is A.root:
            continue
        path = []
        x = t
        while x is not A.root:
            path.append(x)
            x = x.parent
        path.reverse()
        H = [[F(1)]]                       # H at root
        for x in path:
            p = x.parent
            q = p.r if x.is_left else p.l
            Gq = gram(A, q)
            W = A.data[p]
            rp, rx = len(H), A.dim(x)
            Hx = [[F(0)] * rx for _ in range(rx)]
            Ms = [Wi if x.is_left else mat_T(Wi) for Wi in W]
            MGs = [mat_mul(Mi, Gq) for Mi in Ms]
            for i in range(rp):
                for ip in range(rp):
                    h = H[i][ip]
                    if h == 0:
                        continue
                    Pr = mat_mul(MGs[i], mat_T(Ms[ip]))
                    for a in range(rx):
                        ra, Ha = Pr[a], Hx[a]
                        for b in range(rx):
                            if ra[b]:
                                Ha[b] += h * ra[b]
            H = Hx
        r = len(H)
        _, pivcols = rref(H)
        rk = len(pivcols)
        if rk < r:
            MIN_STATS["p2"] += 1
            Kmat = [[H[i][c] for c in pivcols] for i in range(r)]      # r x rk
            Lam = mat_mul(mat_inv(mat_mul(mat_T(Kmat), Kmat)), mat_T(Kmat))
            apply_node_transform(A, t, mat_T(Kmat), mat_T(Lam))
    return A

# ----------------------------------------------------------------------
# canonicalization (lex-RREF gauge via pivot descent)
# ----------------------------------------------------------------------

def index_from_assign(t, d):
    idx = 0
    for v in t.vars:
        idx = (idx << 1) | d[v]
    return idx

def pivot_descent(A, t):
    """Lex-RREF pivots of V_t = span{u_j} (A minimized). Returns
    (pivot indices ascending, P with P[m][j] = u_j(c_m))."""
    r = A.dim(t)
    B = mat_eye(r)
    pivots, evals = [], []
    for _m in range(r):
        partial = {}
        for v in t.vars:
            partial[v] = 0
            Gc = gram(A, t, partial)
            Tm = mat_mul(mat_mul(B, Gc), mat_T(B))
            if sum(Tm[i][i] for i in range(len(Tm))) == 0:
                partial[v] = 1
        Gc = gram(A, t, partial)
        Tm = mat_mul(mat_mul(B, Gc), mat_T(B))
        assert sum(Tm[i][i] for i in range(len(Tm))) != 0, "pivot descent dead end"
        pivots.append(index_from_assign(t, partial))
        ev = point_eval(A, t, partial)
        evals.append(ev)
        w = [sum(B[a][j] * ev[j] for j in range(r)) for a in range(len(B))]
        nz = next((a for a in range(len(w)) if w[a] != 0), None)
        assert nz is not None, "evaluation functional vanishes on S_m"
        B = [[B[a][j] - (w[a] / w[nz]) * B[nz][j] for j in range(r)]
             for a in range(len(B)) if a != nz]
    assert pivots == sorted(set(pivots)), "pivots not strictly ascending"
    return pivots, [[evals[m][j] for j in range(r)] for m in range(r)]

def canonicalize(A):
    """A minimized. Applies the lex-RREF gauge at every non-root bond
    (bottom-up) and returns {node: (pivots, canonical data)}."""
    pivs = {}
    for t in postorder(A.root):
        if t is A.root:
            piv, P = pivot_descent(A, t)
            assert P[0][0] == 1, "root leading value != 1"
            pivs[t] = piv
            continue
        piv, P = pivot_descent(A, t)
        Arows = mat_inv(mat_T(P))      # e_hat = (P^T)^{-1} u
        apply_node_transform(A, t, Arows, mat_T(P))   # u_old = P^T e_hat
        pivs[t] = piv
    canon = {}
    for t in postorder(A.root):
        if t.var is not None:
            canon[t] = (pivs[t], [row[:] for row in A.data[t]])
        else:
            canon[t] = (pivs[t], [[row[:] for row in M] for M in A.data[t]])
    return canon

def canon_equal(c1, c2, root):
    for t in postorder(root):
        if c1[t] != c2[t]:
            return False, t
    return True, None

# ----------------------------------------------------------------------
# bit-size accounting
# ----------------------------------------------------------------------

def max_bits(canon, root):
    mb = 0
    for t in postorder(root):
        _, d = canon[t]
        flat = (x for row in d for x in (row if t.var is not None else
                                         (y for sub in row for y in sub)))
        for x in flat:
            mb = max(mb, x.numerator.bit_length(), x.denominator.bit_length())
    return mb

def hadamard_bit_bound(rho):
    import math
    if rho <= 1:
        return 8
    return int(rho / 2 * math.log2(rho) + math.log2(rho)) + 8

# ----------------------------------------------------------------------
# explicit functions (truth tables in vtree leaf order)
# ----------------------------------------------------------------------

def tt_random(n, rng, density=0.4):
    while True:
        f = [F(1) if rng.random() < density else F(0) for _ in range(1 << n)]
        if any(f):
            return f

def _byvar(idx, root):
    n = root.nv
    bits = [(idx >> (n - 1 - i)) & 1 for i in range(n)]
    return {v: bits[i] for i, v in enumerate(root.vars)}

def tt_hwb(n, root):
    out = []
    for idx in range(1 << n):
        bv = _byvar(idx, root)
        s = sum(bv.values())
        out.append(F(bv[s - 1] if s >= 1 else 0))     # var ids 0..n-1 = x_1..x_n
    return out

def tt_mux(k, root):
    n = k + (1 << k)
    out = []
    for idx in range(1 << n):
        bv = _byvar(idx, root)
        addr = sum(bv[j] << j for j in range(k))
        out.append(F(bv[k + addr]))
    return out

def tt_parity(n, root):
    return [F(bin(idx).count('1') & 1) for idx in range(1 << n)]

def tt_clause(n, lits, root):
    out = []
    for idx in range(1 << n):
        bv = _byvar(idx, root)
        sat = any((bv[v] == 1) == (s == 1) for v, s in lits)
        out.append(F(1) if sat else F(0))
    return out

# ----------------------------------------------------------------------
# tests
# ----------------------------------------------------------------------

PASS = 0
QUIET = 0

def ok(msg):
    global PASS
    PASS += 1
    print(f"  ok  {msg}")

def check(cond, msg):
    if not cond:
        print(f"  FAIL  {msg}")
        sys.exit(1)
    ok(msg)

def check_quiet(cond, msg):
    global QUIET
    if not cond:
        print(f"  FAIL  {msg}")
        sys.exit(1)
    QUIET += 1

def verify_pipeline(f, root, rng, label, expect_dims=None, n_messy=2):
    ranks = brute_ranks(f, root)
    ref = reference_canonical(f, root)
    for t in postorder(root):
        M = cut_matrix(f, root, t)
        S = subfunction_count(M)
        rho = ranks[t]
        check_quiet((rho <= S <= (1 << rho) - 1) if rho > 0 else S == 0,
                    f"{label}: sandwich (rho={rho}, S={S})")
    A0 = build_from_truthtable(f, root)
    check_quiet(func(A0) == f, f"{label}: construction computes f")
    check_quiet(all(A0.dim(t) == ranks[t] for t in postorder(root)),
                f"{label}: construction dims == cut ranks")
    canons = []
    for m in range(n_messy):
        Am = messy(A0, rng) if m > 0 else A0.copy()
        check_quiet(func(Am) == f, f"{label}: messy preserves f")
        minimize(Am)
        check_quiet(func(Am) == f, f"{label}: minimize preserves f")
        check_quiet(all(Am.dim(t) == ranks[t] for t in postorder(root)),
                    f"{label}: minimized dims == cut ranks (V1)")
        canon = canonicalize(Am)
        check_quiet(func(Am) == f, f"{label}: canonicalize preserves f")
        canons.append(canon)
    same, _ = canon_equal(canons[0], ref, root)
    check_quiet(same, f"{label}: network canonical == brute-force reference")
    for c in canons[1:]:
        same, _ = canon_equal(c, canons[0], root)
        check_quiet(same, f"{label}: gauge/padding invariance")
    A1 = build_from_truthtable(f, root)
    minimize(A1)
    c1 = canonicalize(A1)
    c2 = canonicalize(A1)
    same, _ = canon_equal(c1, c2, root)
    check_quiet(same, f"{label}: idempotence")
    if expect_dims is not None:
        check_quiet(max(ranks.values()) <= expect_dims,
                    f"{label}: width {max(ranks.values())} <= {expect_dims}")
    return ranks, canons[0]

def main():
    t0 = time.time()
    rng = random.Random(20260610)

    print("== T1: random functions: realization, sandwich, canonical form ==")
    for trial in range(4):
        n = 6
        root = annotate(random_vtree(list(range(n)), rng))
        f = tt_random(n, rng, density=rng.choice([0.2, 0.4, 0.6]))
        verify_pipeline(f, root, rng, f"random#{trial}", n_messy=3)
    ok("4 random functions x 3 gauge/pad variants: canonical forms identical")

    print("== T2: explicit functions: HWB, MUX, PARITY ==")
    for n in (7, 8):
        for k in range(2):
            root = annotate(random_vtree(list(range(n)), rng))
            f = tt_hwb(n, root)
            ranks, canon = verify_pipeline(f, root, rng, f"HWB{n}",
                                           expect_dims=n + 2, n_messy=2)
            print(f"  HWB_{n} vtree#{k}: max bond {max(ranks.values())}"
                  f" (bound {n + 2}), canonical entry bits"
                  f" {max_bits(canon, root)}")
    for k in (2, 3):
        n = k + (1 << k)
        # vtree with the data block as one subtree, so the sandwich-tightness
        # node X_t = {data vars} is guaranteed to exist
        root = annotate(V(l=random_vtree(list(range(k)), rng),
                          r=random_vtree(list(range(k, n)), rng)))
        f = tt_mux(k, root)
        ranks = brute_ranks(f, root)
        check(max(ranks.values()) <= (1 << k),
              f"MUX k={k}: max bond {max(ranks.values())} <= {1 << k}")
        tight = False
        for t in postorder(root):
            if t.var is None and sorted(t.vars) == list(range(k, n)):
                M = cut_matrix(f, root, t)
                S = subfunction_count(M)
                check(ranks[t] == (1 << k) and S == (1 << ranks[t]) - 1,
                      f"MUX k={k}: S_t = 2^rho - 1 = {S} at data node (tight)")
                tight = True
        check(tight, f"MUX k={k}: data node present in vtree")
        if k == 2:
            verify_pipeline(f, root, rng, "MUX2", expect_dims=1 << k, n_messy=2)
    n = 8
    root = annotate(random_vtree(list(range(n)), rng))
    f = tt_parity(n, root)
    ranks = brute_ranks(f, root)
    inner = [t for t in postorder(root) if t.var is None and t is not root]
    check(all(ranks[t] == 2 for t in inner), "PARITY_8: all internal bonds == 2")

    print("== T2b: fractional canonical entries (exact arithmetic stress) ==")
    # f over 4 vars whose left cut matrix has columns (1,1,0,1),(1,0,1,1),
    # (0,1,1,1),(0,0,0,0): the lex-RREF of that span has entries with
    # denominator 2, so canonical data is genuinely fractional.
    root = annotate(V(l=V(l=V(var=0), r=V(var=1)),
                      r=V(l=V(var=2), r=V(var=3))))
    cols = [(1, 1, 0, 1), (1, 0, 1, 1), (0, 1, 1, 1), (0, 0, 0, 0)]
    f = [F(0)] * 16
    for tau in range(4):
        for sig in range(4):
            f[tau * 4 + sig] = F(cols[sig][tau])
    _, canon = verify_pipeline(f, root, rng, "frac", n_messy=3)
    mbits = max_bits(canon, root)
    check(mbits > 1, f"fractional canonical entries occurred (max bits {mbits})")

    print("== T3: bottom-up CNF pipeline (apply + minimize + canonicalize) ==")
    n = 6
    root = annotate(random_vtree(list(range(n)), rng))
    clauses = [[(v, rng.choice([1, -1])) for v in rng.sample(range(n), 3)]
               for _ in range(8)]
    A_acc, f_acc = None, None
    widths, bitss = [], []
    for ci, cl in enumerate(clauses):
        fc = tt_clause(n, cl, root)
        check_quiet(max(brute_ranks(fc, root).values()) <= 2,
                    f"clause#{ci} factor rank <= 2")
        Ac = build_from_truthtable(fc, root)
        if A_acc is None:
            A_acc, f_acc = Ac, fc
            continue
        f_new = [a * b for a, b in zip(f_acc, fc)]
        if not any(f_new):
            print("  (conjunction UNSAT; stopping early)")
            break
        f_acc = f_new
        A_acc = hadamard(A_acc, Ac)
        minimize(A_acc)
        check_quiet(func(A_acc) == f_acc, f"apply step {ci}: function correct")
        canon = canonicalize(A_acc)
        check_quiet(func(A_acc) == f_acc, f"apply step {ci}: canonical preserves f")
        rho = max(A_acc.dim(t) for t in postorder(root))
        mb = max_bits(canon, root)
        widths.append(rho)
        bitss.append(mb)
        check_quiet(mb <= hadamard_bit_bound(rho),
                    f"apply step {ci}: bits {mb} <= bound {hadamard_bit_bound(rho)}")
    ok(f"CNF pipeline widths per step: {widths}")
    ok(f"CNF pipeline max canonical entry bits per step: {bitss}"
       f" (bounds: {[hadamard_bit_bound(w) for w in widths]})")
    check(model_count(A_acc) == sum(f_acc), "model count via ones-contraction")
    check(is_boolean(A_acc), "promise check: CNF conjunction is Boolean")

    print("== T4: operations: EQ, promise on non-Boolean ==")
    n = 6
    root = annotate(random_vtree(list(range(n)), rng))
    f = tt_random(n, rng)
    A = build_from_truthtable(f, root)
    B = messy(A, rng)
    check(equal_funcs(A, B), "EQ: f == gauged/padded f via sum (f-g)^2")
    f3 = f[:]
    i3 = rng.randrange(len(f3))
    f3[i3] = F(1) - f3[i3]
    B3 = build_from_truthtable(f3, root)
    check(not equal_funcs(A, B3), "EQ: detects single-bit difference")
    check(is_boolean(A), "promise: Boolean f accepted")
    C = A.copy()
    for t in postorder(root):
        if t.var is not None:
            C.data[t] = [[F(rng.randint(-3, 3), rng.randint(1, 4)),
                          F(rng.randint(-3, 3), rng.randint(1, 4))]
                         for _ in range(C.dim(t))]
    if all(x in (F(0), F(1)) for x in func(C)):
        print("  (random network happened to be Boolean; skipping)")
    else:
        check(not is_boolean(C), "promise: non-Boolean network rejected")
    check(model_count(A) == sum(f), "model count matches brute force")

    check(MIN_STATS["p1"] > 0 and MIN_STATS["p2"] > 0,
          f"both minimization phases exercised (phase1: {MIN_STATS['p1']}x, "
          f"phase2: {MIN_STATS['p2']}x)")

    print()
    print(f"ALL CHECKS PASSED: {PASS} reported + {QUIET} quiet"
          f" in {time.time() - t0:.1f}s")

if __name__ == "__main__":
    main()
