#!/usr/bin/env python3
"""Mechanical verification of problems.json for the linear algebra course.

Run:  python3 -I shared/courses/linear-algebra/verify.py     (needs sympy)

How it works. Every problem has a check function below. The check recomputes the
answer and each intermediate result from scratch with sympy (row operations are
replayed one step at a time) and asserts the maths. It then returns the facts it
computed, written in the same notation as the worked solution, and the runner
confirms each fact actually appears in the problem's prompt, worked_solution or
final_answer text. So a wrong number in the JSON, or a step that does not follow,
fails the run. Exit code 0 only if every problem passes.
"""
import json
import os
import sys
from sympy import (Matrix, Rational, symbols, simplify, expand, solve, sqrt,
                   acos, pi, eye, diag, linsolve, S, factor, Poly, GramSchmidt,
                   zeros, EmptySet, cancel)

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = os.path.join(HERE, "problems.json")

x, y, z, w, k, t, s, lam, a, b, c, d, e, f = symbols("x y z w k t s lam a b c d e f")


# ----------------------------------------------------------------- formatting
def norm(text):
    return " ".join(text.replace("−", "-").split())


def num(v):
    v = S(v)
    return str(v)


def M(mat):
    """Matrix -> '[1 2; 3 4]'"""
    rows = ["{}".format(" ".join(num(v) for v in mat.row(i))) for i in range(mat.rows)]
    return "[" + "; ".join(rows) + "]"


def AUG(mat, left):
    rows = []
    for i in range(mat.rows):
        l = " ".join(num(mat[i, j]) for j in range(left))
        r = " ".join(num(mat[i, j]) for j in range(left, mat.cols))
        rows.append(l + " | " + r)
    return "[" + "; ".join(rows) + "]"


def V(*vals):
    return "(" + ", ".join(num(v) for v in vals) + ")"


class R:
    """Row operations, 1-indexed, each returns self so they chain."""

    def __init__(self, rows):
        self.m = Matrix(rows)

    def add(self, i, coef, j):          # R_i -> R_i + coef * R_j
        self.m[i - 1, :] = self.m[i - 1, :] + coef * self.m[j - 1, :]
        return self

    def scale(self, i, coef):           # R_i -> coef * R_i
        self.m[i - 1, :] = coef * self.m[i - 1, :]
        return self

    def swap(self, i, j):
        r = self.m[i - 1, :].copy()
        self.m[i - 1, :] = self.m[j - 1, :]
        self.m[j - 1, :] = r
        return self

    def aug(self, left):
        return AUG(self.m, left)

    def mat(self):
        return M(self.m)


def eq(lhs, rhs):
    assert simplify(S(lhs) - S(rhs)) == 0, f"{lhs} != {rhs}"


def F(prompt=(), sol=(), final=()):
    return dict(prompt=list(prompt), sol=list(sol), final=list(final))


# ----------------------------------------------------------------- topic 1
def c01():
    sol = linsolve([2 * x + y - 7, x - y + 1], x, y)
    assert sol == {(2, 3)}
    eq((2 * x + y) + (x - y), 3 * x); eq(7 + (-1), 6)
    return F(sol=["3x = 6", "x = 2", "y = 3", "2 - y = -1", "2(2) + 3 = 7", "2 - 3 = -1"],
             final=["x = 2, y = 3"])


def c02():
    A = [[1, 1, 1, 6], [2, -1, 1, 3], [1, 2, -1, 2]]
    assert linsolve(Matrix(A)[:, :3].row_join(Matrix(A)[:, 3]), x, y, z) if False else True
    sol = linsolve((Matrix(A)[:, :3], Matrix(A)[:, 3]), x, y, z)
    assert sol == {(1, 2, 3)}
    r = R(A)
    f0 = r.aug(3)
    r.add(2, -2, 1).add(3, -1, 1); f1 = r.aug(3)
    r.swap(2, 3); f2 = r.aug(3)
    r.add(3, 3, 2); f3 = r.aug(3)
    assert r.m[2, 2] == -7 and r.m[2, 3] == -21
    eq(-7 * 3, -21); eq(2 - 2 * 3, -4); eq(6 - 2 - 3, 1)
    return F(sol=[f0, f1, f2, f3, "z = 3", "y = -4 + 6 = 2", "x = 6 - 2 - 3 = 1"],
             final=["(x, y, z) = (1, 2, 3)"])


def c03():
    A = [[1, 2, -1, 3], [2, 5, -1, 8], [1, 3, 2, 7]]
    assert linsolve((Matrix(A)[:, :3], Matrix(A)[:, 3]), x, y, z) == {(2, 1, 1)}
    r = R(A)
    f0 = r.aug(3)
    r.add(2, -2, 1).add(3, -1, 1); f1 = r.aug(3)
    r.add(3, -1, 2).scale(3, Rational(1, 2)); f2 = r.aug(3)
    r.add(1, 1, 3).add(2, -1, 3); f3 = r.aug(3)
    r.add(1, -2, 2); f4 = r.aug(3)
    assert r.m == Matrix([[1, 0, 0, 2], [0, 1, 0, 1], [0, 0, 1, 1]])
    return F(sol=[f0, f1, f2, f3, f4, "x = 2, y = 1, z = 1"], final=["(x, y, z) = (2, 1, 1)"])


def c04():
    A = [[1, 1, 1, 2], [1, 2, 3, 5], [2, 3, 4, 9]]
    assert linsolve((Matrix(A)[:, :3], Matrix(A)[:, 3]), x, y, z) == EmptySet
    r = R(A)
    f0 = r.aug(3)
    r.add(2, -1, 1).add(3, -2, 1); f1 = r.aug(3)
    r.add(3, -1, 2); f2 = r.aug(3)
    return F(sol=[f0, f1, f2, "0 = 2"], final=["No solution"])


def c05():
    A = [[1, 1, 2, 4], [2, 3, 5, 11]]
    sol = linsolve((Matrix(A)[:, :3], Matrix(A)[:, 3]), x, y, z)
    (tup,) = list(sol)
    free = list(tup[2].free_symbols)[0]
    eq(tup[0], 1 - free); eq(tup[1], 3 - free)
    r = R(A)
    f0 = r.aug(3)
    r.add(2, -2, 1); f1 = r.aug(3)
    r.add(1, -1, 2); f2 = r.aug(3)
    assert (1 + 3, 2 * 1 + 3 * 3 + 0) == (4, 11)
    return F(sol=[f0, f1, f2, "x = 1 - t and y = 3 - t", "(1, 3, 0) gives 1 + 3 = 4 and 2 + 9 = 11"],
             final=["(x, y, z) = (1 - t, 3 - t, t)"])


def c06():
    # eliminate x
    r = R([[1, 2, 3], [3, k, 10]]); r.add(2, -3, 1)
    assert simplify(r.m[1, 1] - (k - 6)) == 0 and r.m[1, 2] == 1
    # k=6 inconsistent; otherwise unique
    A6 = Matrix([[1, 2], [3, 6]]); assert linsolve((A6, Matrix([3, 10])), x, y) == EmptySet
    for kv in (0, 1, 5, 7, -3, 10):
        sol = linsolve((Matrix([[1, 2], [3, kv]]), Matrix([3, 10])), x, y)
        assert len(sol) == 1
        (xs, ys), = sol
        eq(ys, Rational(1, kv - 6)); eq(xs, 3 - 2 * ys)
    return F(sol=["[1 2 | 3; 0 k-6 | 1]", "(k - 6)y = 1", "k = 6", "0 = 1", "y = 1 / (k - 6)", "x = 3 - 2y"],
             final=["No solution when k = 6; exactly one solution when k != 6".replace("!=", "≠")])


# ----------------------------------------------------------------- topic 2
def c07():
    A = Matrix([[2, -1], [0, 3]]); B = Matrix([[1, 4], [-2, 5]])
    AB, BA = A * B, B * A
    assert AB == Matrix([[4, 3], [-6, 15]]) and BA == Matrix([[2, 11], [-4, 17]]) and AB != BA
    return F(prompt=["A = " + M(A), "B = " + M(B)],
             sol=["2(1) + (-1)(-2) = 4", "2(4) + (-1)(5) = 3", "0(1) + 3(-2) = -6", "0(4) + 3(5) = 15",
                  "AB = " + M(AB), "1(2) + 4(0) = 2", "1(-1) + 4(3) = 11", "-2(2) + 5(0) = -4",
                  "-2(-1) + 5(3) = 17", "BA = " + M(BA)],
             final=["AB = " + M(AB), "BA = " + M(BA)])


def c08():
    A = Matrix([[1, 0, 2], [-1, 3, 1]]); B = Matrix([[2, 1], [0, -1], [3, 4]])
    AB = A * B
    assert AB == Matrix([[8, 9], [1, 0]]) and AB.T == B.T * A.T == Matrix([[8, 1], [9, 0]])
    assert 1 * 2 + 0 * 0 + 2 * 3 == 8 and 1 * 1 + 0 * -1 + 2 * 4 == 9
    assert -1 * 2 + 3 * 0 + 1 * 3 == 1 and -1 * 1 + 3 * -1 + 1 * 4 == 0
    assert 2 * 1 + 0 * 0 + 3 * 2 == 8 and 2 * -1 + 0 * 3 + 3 * 1 == 1
    assert 1 * 1 - 1 * 0 + 4 * 2 == 9 and 1 * -1 - 1 * 3 + 4 * 1 == 0
    return F(prompt=["A = " + M(A), "B = " + M(B)],
             sol=["AB = " + M(AB), "(AB)T".replace("T", "ᵀ") + " = " + M(AB.T), "Bᵀ = " + M(B.T),
                  "Aᵀ = " + M(A.T), "BᵀAᵀ = " + M(B.T * A.T), "-1(2) + 3(0) + 1(3)",
                  "-1(1) + 3(-1) + 1(4)"],
             final=["(AB)ᵀ = " + M(AB.T)])


def c09():
    A = Matrix([[2, 1], [5, 3]])
    r = R(Matrix.hstack(A, eye(2)))
    f0 = r.aug(2)
    r.add(2, -2, 1); f1 = r.aug(2)
    r.add(1, -1, 2); f2 = r.aug(2)
    r.add(2, -1, 1); f3 = r.aug(2)
    inv = A.inv()
    assert r.m[:, 2:] == inv == Matrix([[3, -1], [-5, 2]]) and A * inv == eye(2)
    return F(prompt=["A = " + M(A)],
             sol=[f0, f1, f2, f3, "A⁻¹ = " + M(inv), "2(3) + 1(-5)", "2(-1) + 1(2)", "5(3) + 3(-5)",
                  "5(-1) + 3(2)", "= [1 0; 0 1]"],
             final=["A⁻¹ = " + M(inv)])


def c10():
    A = Matrix([[1, 0, 2], [0, 1, 1], [1, 1, 4]])
    r = R(Matrix.hstack(A, eye(3)))
    f0 = r.aug(3)
    r.add(3, -1, 1); f1 = r.aug(3)
    r.add(3, -1, 2); f2 = r.aug(3)
    r.add(1, -2, 3).add(2, -1, 3); f3 = r.aug(3)
    assert r.m[:, 3:] == A.inv() == Matrix([[3, 2, -2], [1, 2, -1], [-1, -1, 1]])
    return F(prompt=["A = " + M(A)], sol=[f0, f1, f2, f3, "A⁻¹ = " + M(A.inv())],
             final=["A⁻¹ = " + M(A.inv())])


def c11():
    A = Matrix([[3, 5], [1, 2]]); Bv = Matrix([11, 4])
    assert A.det() == 1
    inv = A.inv(); assert inv == Matrix([[2, -5], [-1, 3]])
    X = inv * Bv; assert X == Matrix([2, 1])
    assert 2 * 11 - 5 * 4 == 2 and -1 * 11 + 3 * 4 == 1
    return F(sol=["A = [3 5; 1 2]", "det A = 3(2) - 5(1) = 1", "(1/1)[2 -5; -1 3] = " + M(inv),
                  "2(11) - 5(4), -1(11) + 3(4)) = (2, 1)", "3(2) + 5(1) = 11", "2 + 2(1) = 4"],
             final=["x = 2, y = 1"])


def c12():
    A = Matrix([[1, 2], [1, 3]]); B = Matrix([[1, 0], [2, 1]]); C = Matrix([[4, 3], [7, 5]])
    CB = C - B; assert CB == Matrix([[3, 3], [5, 4]])
    assert A.det() == 1 and A.inv() == Matrix([[3, -2], [-1, 1]])
    X = A.inv() * CB; assert X == Matrix([[-1, 1], [2, 1]])
    assert A * X + B == C and A * X == Matrix([[3, 3], [5, 4]])
    return F(prompt=["A = " + M(A), "B = " + M(B), "C = " + M(C)],
             sol=["AX = C - B = " + M(CB), "A⁻¹ = " + M(A.inv()), "3(3) - 2(5)", "3(3) - 2(4)",
                  "-1(3) + 1(5)", "-1(3) + 1(4)", "X = " + M(X), "A X = " + M(A * X), "AX + B = " + M(C)],
             final=["X = " + M(X)])


def c13():
    A = Matrix([[1, 1], [0, 1]]); B = Matrix([[1, 0], [1, 1]])
    L = (A + B) ** 2; Rr = A ** 2 + 2 * A * B + B ** 2
    assert L == Matrix([[5, 4], [4, 5]]) and Rr == Matrix([[6, 4], [4, 4]]) and L != Rr
    assert A * B == Matrix([[2, 1], [1, 1]]) and B * A == Matrix([[1, 1], [1, 2]]) and A * B != B * A
    assert A ** 2 == Matrix([[1, 2], [0, 1]]) and B ** 2 == Matrix([[1, 0], [2, 1]])
    assert A + B == Matrix([[2, 1], [1, 2]])
    return F(prompt=["A = " + M(A), "B = " + M(B)],
             sol=["A + B = " + M(A + B), "(A + B)² = " + M(L), "A² = " + M(A ** 2), "AB = " + M(A * B),
                  "B² = " + M(B ** 2), "1 + 4 + 1, 2 + 2 + 0; 0 + 2 + 2, 1 + 2 + 1", "= " + M(Rr),
                  "BA = " + M(B * A)],
             final=["(A + B)² = " + M(L), M(Rr)])


# ----------------------------------------------------------------- topic 3
def c14():
    A = Matrix([[k, 6], [2, 4]])
    eq(A.det(), 4 * k - 12)
    assert solve(A.det(), k) == [3]
    return F(prompt=["[k 6; 2 4]"], sol=["k(4) - 6(2) = 4k - 12", "4k - 12 = 0 gives k = 3"], final=["k = 3"])


def c15():
    A = Matrix([[2, 0, 1], [3, 1, -1], [0, 4, 2]])
    assert Matrix([[1, -1], [4, 2]]).det() == 6 and Matrix([[3, 1], [0, 4]]).det() == 12
    assert 2 * 6 - 0 + 1 * 12 == 24 == A.det()
    assert 1 * 2 - (-1) * 4 == 6 and 3 * 4 - 1 * 0 == 12
    return F(prompt=["[2 0 1; 3 1 -1; 0 4 2]"],
             sol=["det[1 -1; 4 2] = 1(2) - (-1)(4) = 6", "det[3 1; 0 4] = 3(4) - 1(0) = 12",
                  "det = 2(6) - 0 + 1(12) = 24"], final=["det = 24"])


def c16():
    A = [[1, 2, 3], [2, 5, 7], [3, 7, 11]]
    r = R(A); r.add(2, -2, 1).add(3, -3, 1); f1 = r.mat()
    r.add(3, -1, 2); f2 = r.mat()
    assert Matrix(A).det() == 1 and r.m.det() == 1 and r.m[0, 0] * r.m[1, 1] * r.m[2, 2] == 1
    return F(prompt=["[1 2 3; 2 5 7; 3 7 11]"], sol=[f1, f2, "1 · 1 · 1 = 1"], final=["det = 1"])


def c17():
    A = Matrix([[1, 2, 0], [0, 2, 1], [0, 0, 2]]); assert A.det() == 4
    P = Matrix([[1, 1, 0], [0, 1, 0], [1, 0, 1]])
    A = P * A * P.inv(); assert A.det() == 4          # a non-triangular test matrix
    assert (2 * A).det() == 32 and A.inv().det() == Rational(1, 4) and (A ** 3).det() == 64
    assert A.adjugate().det() == 16
    return F(sol=["2³ det A = 8 · 4 = 32", "1 / det A = 1/4", "(det A)³ = 4³ = 64",
                  "4³ / 4 = 16"],
             final=["det(2A) = 32", "det(A⁻¹) = 1/4", "det(A³) = 64", "det(adj A) = 16"])


def c18():
    A = Matrix([[2, 1, 0], [0, 1, 1], [1, 0, 1]])
    assert A.det() == 3
    assert 2 * (1 * 1 - 1 * 0) - 1 * (0 * 1 - 1 * 1) + 0 == 3
    C = A.cofactor_matrix(); assert C == Matrix([[1, 1, -1], [-1, 2, 1], [1, -2, 2]])
    adj = A.adjugate(); assert adj == C.T == Matrix([[1, -1, 1], [1, 2, -2], [-1, 1, 2]])
    assert adj / 3 == A.inv()
    assert (1 * 1 - 1 * 0, -(0 * 1 - 1 * 1), 0 * 0 - 1 * 1) == (1, 1, -1)
    return F(prompt=["A = " + M(A)],
             sol=["= 2 + 1 = 3", "C = " + M(C), "C11 = +(1·1 - 1·0) = 1", "C12 = -(0·1 - 1·1) = 1",
                  "C13 = +(0·0 - 1·1) = -1", "adj A = Cᵀ = " + M(adj),
                  "(1/3)" + M(adj)],
             final=["A⁻¹ = (1/3)" + M(adj)])


def c19():
    A = Matrix([[3, 2], [1, 4]]); bb = Matrix([8, 6])
    D = A.det(); Dx = Matrix([[8, 2], [6, 4]]).det(); Dy = Matrix([[3, 8], [1, 6]]).det()
    assert (D, Dx, Dy) == (10, 20, 10) and (Dx / D, Dy / D) == (2, 1)
    assert A * Matrix([2, 1]) == bb
    return F(sol=["det[3 2; 1 4] = 12 - 2 = 10", "det[8 2; 6 4] = 32 - 12 = 20", "det[3 8; 1 6] = 18 - 8 = 10",
                  "x = Dx / D = 20/10 = 2", "y = Dy / D = 10/10 = 1"], final=["x = 2, y = 1"])


def c20():
    A = Matrix([[1, 1, 1], [1, 2, 3], [1, 4, 9]]); bb = Matrix([2, 3, 7])
    assert A.det() == 2
    Az = A.copy(); Az[:, 2] = bb
    assert Az == Matrix([[1, 1, 2], [1, 2, 3], [1, 4, 7]]) and Az.det() == 2
    assert A.LUsolve(bb)[2] == 1
    assert 1 * (18 - 12) - 1 * (9 - 3) + 1 * (4 - 2) == 2 and 1 * (14 - 12) - 1 * (7 - 3) + 2 * (4 - 2) == 2
    return F(sol=["= 6 - 6 + 2 = 2", "Dz = det[1 1 2; 1 2 3; 1 4 7]", "= 2 - 4 + 4 = 2", "z = Dz / D = 2/2 = 1"],
             final=["z = 1"])


def c21():
    Mt = Matrix([[1, 2, 3], [4, 5, 6], [7, 8, t]])
    eq(Mt.det(), -3 * (t - 9)); assert solve(Mt.det(), t) == [9]
    r = R(Mt); r.add(2, -4, 1).add(3, -7, 1)
    assert list(r.m[1, :]) == [0, -3, -6] and simplify(r.m[2, 2] - (t - 21)) == 0
    r.add(3, -2, 2)
    assert list(r.m[2, :]) == [0, 0, t - 9] or simplify(r.m[2, 2] - (t - 9)) == 0
    return F(prompt=["[1 2 3; 4 5 6; 7 8 t]"],
             sol=["[1 2 3; 0 -3 -6; 0 -6 t-21]", "[1 2 3; 0 -3 -6; 0 0 t-9]", "1 · (-3) · (t - 9)", "t = 9"],
             final=["t = 9"])


# ----------------------------------------------------------------- topic 4
def c22():
    a_, b_, c_, d_, e_, f_, kk = symbols("a_ b_ c_ d_ e_ f_ kk")
    lhs = (a_ + d_) + 2 * (b_ + e_) - (c_ + f_)
    eq(lhs, (a_ + 2 * b_ - c_) + (d_ + 2 * e_ - f_))
    eq(kk * a_ + 2 * kk * b_ - kk * c_, kk * (a_ + 2 * b_ - c_))
    assert 0 + 2 * 0 - 0 == 0
    return F(sol=["0 + 2(0) - 0 = 0", "(a + d) + 2(b + e) - (c + f) = (a + 2b - c) + (d + 2e - f) = 0 + 0 = 0",
                  "ka + 2(kb) - kc = k(a + 2b - c) = k · 0 = 0"],
             final=["W is a subspace"])


def c23():
    assert (0 == 0 + 1) is False
    return F(sol=["0 = 0 + 1, which is false", "not a subspace"], final=["Not a subspace"])


def c24():
    v1 = Matrix([1, 2, 1]); v2 = Matrix([3, 1, -2]); wv = Matrix([5, 5, 0])
    sol = linsolve((Matrix.hstack(v1, v2), wv), a, b); assert sol == {(2, 1)}
    assert 2 * v1 + 1 * v2 == wv and 2 * 2 + 1 == 5 and 2 + 3 * 1 == 5
    return F(sol=["a + 3b = 5, 2a + b = 5, a - 2b = 0", "a = 2b", "5b = 5", "b = 1 and a = 2", "2(2) + 1 = 5",
                  "2 + 3(1) = 5", "w = 2v₁ + 1v₂"], final=["w = 2v₁ + v₂"])


def c25():
    v1 = Matrix([1, 0, 1]); v2 = Matrix([0, 1, 1]); bb = Matrix([1, 1, 3])
    assert linsolve((Matrix.hstack(v1, v2), bb), a, c) == EmptySet
    return F(sol=["(a, c, a + c) = (1, 1, 3)", "a = 1 and c = 1", "a + c = 2", "must be 3"],
             final=["No, b is not in the span"])


def c26():
    v1, v2, v3 = Matrix([1, 2, 3]), Matrix([2, 1, 0]), Matrix([0, 3, 6])
    A = Matrix.hstack(v1, v2, v3); assert A.rank() == 2
    r = R(A); f0 = r.mat()
    r.add(2, -2, 1).add(3, -3, 1); f1 = r.mat()
    r.add(3, -2, 2); f2 = r.mat()
    assert -2 * v1 + v2 + v3 == zeros(3, 1) and A.nullspace()[0] == Matrix([-2, 1, 1])
    return F(sol=[f0, f1, f2, "c₂ = 1", "c₁ = -2", "-2(1, 2, 3) + (2, 1, 0) + (0, 3, 6) = (0, 0, 0)"],
             final=["Linearly dependent: -2v₁ + v₂ + v₃ = 0"])


def c27():
    A = Matrix([[1, 1, 0], [1, 0, 1], [0, 1, 1]])
    assert A.det() == -2 and 1 * (0 * 1 - 1 * 1) - 1 * (1 * 1 - 1 * 0) + 0 == -2
    return F(sol=["= -1 - 1 = -2", "-2 ≠ 0"], final=["det = -2"])


def c28():
    A = Matrix([[1, 2, 0, 1], [2, 4, 1, 5], [3, 6, 1, 6]])
    r = R(A); r.add(2, -2, 1).add(3, -3, 1); f1 = r.mat()
    r.add(3, -1, 2); f2 = r.mat()
    rref, piv = A.rref(); assert A.rank() == 2 and piv == (0, 2)
    cs = A.columnspace(); assert cs[0] == Matrix([1, 2, 3]) and cs[1] == Matrix([0, 1, 1])
    rs = [list(rw) for rw in A.rowspace()]
    assert Matrix.vstack(*A.rowspace()).rank() == 2
    # row space of A equals span of echelon rows
    assert Matrix([[1, 2, 0, 1], [0, 0, 1, 3]]).rank() == 2 and Matrix([[1, 2, 0, 1], [0, 0, 1, 3], list(A.row(0)), list(A.row(1)), list(A.row(2))]).rank() == 2
    return F(prompt=["A = " + M(A)],
             sol=[f1, f2, "rank A = 2", "(1, 2, 3) and (0, 1, 1)", "(1, 2, 0, 1) and (0, 0, 1, 3)"],
             final=["rank 2", "{(1, 2, 3), (0, 1, 1)}", "{(1, 2, 0, 1), (0, 0, 1, 3)}"])


def c29():
    A = Matrix([[1, 2, 1, 3], [2, 4, 3, 7]])
    r = R(A); r.add(2, -2, 1); f1 = r.mat()
    r.add(1, -1, 2); f2 = r.mat()
    ns = A.nullspace(); assert A.rank() == 2 and len(ns) == 2
    n1, n2 = Matrix([-2, 1, 0, 0]), Matrix([-2, 0, -1, 1])
    assert A * n1 == zeros(2, 1) and A * n2 == zeros(2, 1)
    assert Matrix.hstack(n1, n2).rank() == 2 and Matrix.hstack(n1, n2, *ns).rank() == 2
    return F(prompt=["A = " + M(A)],
             sol=[f1, f2, "x = -2s - 2t and z = -t", "s(-2, 1, 0, 0) + t(-2, 0, -1, 1)",
                  "rank = 2, nullity = 2"],
             final=["{(-2, 1, 0, 0), (-2, 0, -1, 1)}", "rank 2, nullity 2"])


# ----------------------------------------------------------------- topic 5
def c30():
    u = Matrix([1, 1, 0]); v = Matrix([0, 1, 1])
    assert u.dot(v) == 1 and u.norm() == sqrt(2) == v.norm()
    cos = u.dot(v) / (u.norm() * v.norm()); assert cos == Rational(1, 2) and acos(cos) == pi / 3
    return F(sol=["u · v = 1(0) + 1(1) + 0(1) = 1", "√2", "1 / 2", "60°"], final=["60°"])


def c31():
    assert set(solve(k * k + 2 * -3 + 1 * 5, k)) == {1, -1}
    return F(sol=["k(k) + 2(-3) + 1(5) = k² - 6 + 5 = k² - 1", "k = 1 or k = -1"],
             final=["k = 1 or k = -1"])


def c32():
    u = Matrix([3, 0, 3]); v = Matrix([1, 2, 2])
    assert u.dot(v) == 9 and v.dot(v) == 9
    p = (u.dot(v) / v.dot(v)) * v; assert p == v
    o = u - p; assert o == Matrix([2, -2, 1]) and o.dot(v) == 0
    return F(sol=["3(1) + 0(2) + 3(2) = 9", "1 + 4 + 4 = 9", "(9/9)(1, 2, 2) = (1, 2, 2)", "(2, -2, 1)",
                  "2 - 4 + 2 = 0"], final=["proj = (1, 2, 2)", "(2, -2, 1)"])


def c33():
    n = Matrix([[1, 2, -1]])
    ns = n.nullspace(); assert len(ns) == 2
    b1, b2 = Matrix([-2, 1, 0]), Matrix([1, 0, 1])
    assert n * b1 == zeros(1, 1) and n * b2 == zeros(1, 1) and Matrix.hstack(b1, b2).rank() == 2
    return F(sol=["x + 2y - z = 0", "x = -2y + z", "y(-2, 1, 0) + z(1, 0, 1)", "-2 + 2 = 0", "1 - 1 = 0"],
             final=["{(-2, 1, 0), (1, 0, 1)}"])


def c34():
    P = Matrix([1, 0, 2]); Q = Matrix([2, 1, 2]); Rr = Matrix([1, 1, 4])
    PQ, PR = Q - P, Rr - P
    assert PQ == Matrix([1, 1, 0]) and PR == Matrix([0, 1, 2])
    cr = PQ.cross(PR); assert cr == Matrix([2, -2, 1]) and cr.norm() == 3
    assert (1 * 2 - 0 * 1, 0 * 0 - 1 * 2, 1 * 1 - 1 * 0) == (2, -2, 1)
    return F(sol=["PQ = Q - P = (1, 1, 0)", "PR = R - P = (0, 1, 2)", "(2, -2, 1)", "√(4 + 4 + 1) = 3", "3/2"],
             final=["Area = 3/2"])


def c35():
    P = Matrix([1, 2, 0]); Q = Matrix([2, 1, 1]); Rr = Matrix([0, 1, 3])
    PQ, PR = Q - P, Rr - P
    assert PQ == Matrix([1, -1, 1]) and PR == Matrix([-1, -1, 3])
    n = PQ.cross(PR); assert n == Matrix([-2, -4, -2])
    n1 = Matrix([1, 2, 1]); assert n == -2 * n1
    dd = n1.dot(P); assert dd == 5 and n1.dot(Q) == 5 and n1.dot(Rr) == 5
    assert ((-1) * 3 - 1 * (-1), 1 * (-1) - 1 * 3, 1 * (-1) - (-1) * (-1)) == (-2, -4, -2)
    return F(sol=["PQ = (1, -1, 1)", "PR = (-1, -1, 3)", "(-2, -4, -2)", "(1, 2, 1)", "d = 1 + 4 + 0 = 5",
                  "2 + 2 + 1 = 5", "0 + 2 + 3 = 5"], final=["x + 2y + z = 5"])


def c36():
    P = Matrix([4, 0, 1]); n = Matrix([2, -2, 1]); dd = 3
    dist = abs(n.dot(P) - dd) / n.norm(); assert dist == 2
    return F(sol=["|2(4) - 2(0) + 1(1) - 3| = |8 + 1 - 3| = 6", "√(4 + 4 + 1) = 3", "6/3 = 2"],
             final=["Distance = 2"])


def c37():
    A = Matrix([1, 0, 1]); P = Matrix([4, 3, 1]); dv = Matrix([1, 2, 2])
    AP = P - A; assert AP == Matrix([3, 3, 0]) and AP.dot(dv) == 9 and dv.dot(dv) == 9
    perp = AP - (AP.dot(dv) / dv.dot(dv)) * dv; assert perp == Matrix([2, 1, -2]) and perp.norm() == 3
    assert AP.cross(dv).norm() / dv.norm() == 3        # cross-product method agrees
    return F(sol=["(3, 3, 0)", "3 + 6 + 0 = 9", "(1, 2, 2)", "(3, 3, 0) - (1, 2, 2) = (2, 1, -2)",
                  "√(4 + 1 + 4) = 3"], final=["Distance = 3"])


def c38():
    A = Matrix([1, 2, 3]); B = Matrix([3, 1, 5])
    dv = B - A; assert dv == Matrix([2, -1, 2])
    line = A + t * dv; assert list(line) == [1 + 2 * t, 2 - t, 3 + 2 * t]
    tv = solve(sum(line) - 12, t); assert tv == [2]
    pt = line.subs(t, 2); assert pt == Matrix([5, 0, 7]) and sum(pt) == 12
    assert sum(line) == 6 + 3 * t
    return F(sol=["d = B - A = (2, -1, 2)", "x = 1 + 2t, y = 2 - t, z = 3 + 2t",
                  "(x - 1)/2 = (y - 2)/(-1) = (z - 3)/2", "(1 + 2t) + (2 - t) + (3 + 2t) = 12", "6 + 3t = 12",
                  "t = 2", "(5, 0, 7)", "5 + 0 + 7 = 12"], final=["(5, 0, 7)"])


# ----------------------------------------------------------------- topic 6
def c39():
    p = a + b * x + c * x ** 2
    assert p.subs(x, 1) == a + b + c
    eq(b * (x - 1) + c * (x ** 2 - 1), (-b - c) + b * x + c * x ** 2)
    assert (x - 1).subs(x, 1) == 0 and (x ** 2 - 1).subs(x, 1) == 0
    return F(sol=["p(1) = a + b + c = 0", "(p + q)(1) = 0 + 0 = 0", "a = -b - c", "b(x - 1) + c(x² - 1)",
                  "dim W = 2"], final=["{x - 1, x² - 1}", "dim 2"])


def c40():
    zero = S(0); assert zero.subs(x, 0) == 0 != 1
    q = 2 * (1 + x); assert q.subs(x, 0) == 2
    return F(sol=["p(0) = 0, not 1", "2(1 + x)", "value 2 at 0", "Not a subspace"], final=["Not a subspace"])


def c41():
    A = Matrix([[a, b], [b, d]]); assert A == A.T
    B = Matrix([[c, e], [e, f]]); assert (A + B) == (A + B).T and (k * A) == (k * A).T
    eq(0, 0)
    comb = a * Matrix([[1, 0], [0, 0]]) + b * Matrix([[0, 1], [1, 0]]) + d * Matrix([[0, 0], [0, 1]])
    assert comb == A
    stack = Matrix([[1, 0, 0, 0], [0, 1, 1, 0], [0, 0, 0, 1]]); assert stack.rank() == 3
    return F(sol=["A = [a b; b d]", "(A + B)ᵀ = Aᵀ + Bᵀ = A + B", "(kA)ᵀ = kAᵀ = kA",
                  "[a b; b d] = a[1 0; 0 0] + b[0 1; 1 0] + d[0 0; 0 1]", "dimension 3"],
             final=["{[1 0; 0 0], [0 1; 1 0], [0 0; 0 1]}", "dim 3"])


def c42():
    A = Matrix([[1, 0], [0, 0]]); B = Matrix([[0, 0], [0, 1]])
    assert A.det() == 0 and B.det() == 0 and (A + B) == eye(2) and (A + B).det() == 1
    return F(sol=["A = [1 0; 0 0]", "B = [0 0; 0 1]", "det = 0", "A + B = [1 0; 0 1]", "det = 1"],
             final=["Not a subspace"])


def c43():
    # coefficient columns (constant, x, x^2)
    A = Matrix([[1, 1, 0], [0, 1, 1], [1, 0, 1]])   # columns = c1:(1,1,0)?? built below
    p1, p2, p3 = (1 + x), (x + x ** 2), (1 + x ** 2)
    cols = [[Poly(p, x).coeff_monomial(m) for m in (1, x, x ** 2)] for p in (p1, p2, p3)]
    C = Matrix(cols).T
    assert C.det() == 2 and C.nullspace() == []
    assert solve([c + b - 0 if False else a + c, a + b, b + c], [a, b, c], dict=True) == [{a: 0, b: 0, c: 0}]
    return F(sol=["c₁ + c₃ = 0", "c₁ + c₂ = 0", "c₂ + c₃ = 0", "c₁ = 0",
                  "c₂ = 0 and c₃ = 0", "dim P₂ = 3"], final=["Independent", "a basis of P₂"])


def c44():
    E = [Matrix([[1, 0], [0, 1]]), Matrix([[1, 1], [0, 0]]), Matrix([[0, 1], [1, 0]]), Matrix([[0, 0], [1, 1]])]
    comb = a * E[0] + b * E[1] + c * E[2] + d * E[3]
    assert comb == Matrix([[a + b, b + c], [c + d, a + d]])
    cols = Matrix([list(Ei) for Ei in E]).T
    assert cols.rank() == 3 and len(cols.nullspace()) == 1 and cols * Matrix([1, -1, 1, -1]) == zeros(4, 1)
    assert E[0] - E[1] + E[2] - E[3] == zeros(2, 2)
    return F(prompt=["[1 0; 0 1]", "[1 1; 0 0]", "[0 1; 1 0]", "[0 0; 1 1]"],
             sol=["[a + b, b + c; c + d, a + d]", "a + b = 0, b + c = 0, c + d = 0, a + d = 0",
                  "b = -a, c = a, d = -a", "(a, b, c, d) = (1, -1, 1, -1)", "not a basis"],
             final=["Not a basis"])


def c45():
    p1, p2, p3 = (1 + x), (x + x ** 2), (1 + x ** 2)
    sol = solve([a + c - 1, a + b - 3, b + c], [a, b, c], dict=True)
    assert sol == [{a: 2, b: 1, c: -1}]
    eq(2 * p1 + p2 - p3, 1 + 3 * x)
    return F(sol=["c₁ + c₃ = 1", "c₁ + c₂ = 3", "c₂ + c₃ = 0", "c₂ = -c₃",
                  "c₁ = 3 + c₃", "3 + 2c₃ = 1", "c₃ = -1", "c₂ = 1 and c₁ = 2",
                  "2(1 + x) + (x + x²) - (1 + x²) = 1 + 3x"],
             final=["(2, 1, -1)"])


# ----------------------------------------------------------------- topic 7
def c46():
    ip = lambda p, q: sum(p.subs(x, v) * q.subs(x, v) for v in (0, 1, -1))
    p = 1 - x; q = 2 + x ** 2
    assert [p.subs(x, v) for v in (0, 1, -1)] == [1, 0, 2] and [q.subs(x, v) for v in (0, 1, -1)] == [2, 3, 3]
    assert ip(p, q) == 8 and ip(p, p) == 5
    return F(sol=["p(0) = 1, p(1) = 0, p(-1) = 2", "q(0) = 2, q(1) = 3, q(-1) = 3", "1(2) + 0(3) + 2(3) = 8",
                  "1 + 0 + 4 = 5", "√5"], final=["= 8", "√5"])


def c47():
    A = Matrix([[1, x], [2, 1]]); B = Matrix([[2, 1], [1, -2]])
    ip = sum(A[i, j] * B[i, j] for i in range(2) for j in range(2))
    eq(ip, x + 2); assert solve(ip, x) == [-2]
    return F(prompt=["A = " + "[1 x; 2 1]", "B = " + M(B)],
             sol=["1(2) + x(1) + 2(1) + 1(-2)", "x + 2", "x = -2"], final=["x = -2"])


def c48():
    v1 = Matrix([1, 1, 1]); v2 = Matrix([1, 2, 0])
    u1 = v1
    assert v2.dot(u1) == 3 and u1.dot(u1) == 3
    u2 = v2 - (v2.dot(u1) / u1.dot(u1)) * u1; assert u2 == Matrix([0, 1, -1]) and u1.dot(u2) == 0
    assert u1.norm() == sqrt(3) and u2.norm() == sqrt(2)
    gs = GramSchmidt([v1, v2]); assert gs[1] == u2
    return F(sol=["(1, 2, 0) - (1, 1, 1) = (0, 1, -1)", "1 + 2 + 0 = 3", "0 + 1 - 1 = 0", "√3", "√2",
                  "(1/√3)(1, 1, 1)", "(1/√2)(0, 1, -1)"],
             final=["u₂ = (0, 1, -1)"])


def c49():
    v1, v2, v3 = Matrix([1, 1, 0]), Matrix([1, 0, 1]), Matrix([0, 1, 1])
    u1 = v1; assert u1.dot(u1) == 2
    assert v2.dot(u1) == 1
    u2 = v2 - Rational(1, 2) * u1; assert u2 == Matrix([Rational(1, 2), Rational(-1, 2), 1]) and u2.dot(u2) == Rational(3, 2)
    assert v3.dot(u1) == 1 and v3.dot(u2) == Rational(1, 2)
    u3 = v3 - (v3.dot(u1) / u1.dot(u1)) * u1 - (v3.dot(u2) / u2.dot(u2)) * u2
    assert u3 == Matrix([Rational(-2, 3), Rational(2, 3), Rational(2, 3)])
    assert u3.dot(u1) == 0 and u3.dot(u2) == 0
    assert GramSchmidt([v1, v2, v3]) == [u1, u2, u3]
    return F(sol=["u₁ = v₁ = (1, 1, 0)", "u₂ = v₂ - (1/2)u₁ = (1/2, -1/2, 1)", "3/2",
                  "v₃ · u₂ = -1/2 + 1 = 1/2", "(1/3)(1/2, -1/2, 1)", "(-2/3, 2/3, 2/3)",
                  "-2/3 + 2/3 = 0", "-1/3 - 1/3 + 2/3 = 0"],
             final=["u₃ = (-2/3, 2/3, 2/3)", "u₂ = (1/2, -1/2, 1)"])


def c50():
    w1 = Matrix([1, 1, 0]); w2 = Matrix([1, -1, 1]); bb = Matrix([3, 1, 4])
    assert w1.dot(w2) == 0 and bb.dot(w1) == 4 and w1.dot(w1) == 2 and bb.dot(w2) == 6 and w2.dot(w2) == 3
    p = 2 * w1 + 2 * w2; assert p == Matrix([4, 0, 2])
    r = bb - p; assert r == Matrix([-1, 1, 2]) and r.dot(w1) == 0 and r.dot(w2) == 0 and r.norm() == sqrt(6)
    # independent confirmation by least squares: minimise |b - (s w1 + t w2)|^2
    sol = solve([ (bb - s * w1 - t * w2).dot(w1), (bb - s * w1 - t * w2).dot(w2)], [s, t], dict=True)
    assert sol == [{s: 2, t: 2}]
    return F(sol=["1 - 1 + 0 = 0", "b · w₁ = 4", "w₁ · w₁ = 2", "3 - 1 + 4 = 6", "w₂ · w₂ = 3",
                  "(4, 0, 2)", "(-1, 1, 2)", "-1 - 1 + 2 = 0", "√6"],
             final=["(4, 0, 2)", "√6"])


# ----------------------------------------------------------------- topic 8
def c51():
    x1, y1, x2, y2, kk = symbols("x1 y1 x2 y2 kk")
    T = lambda X, Y: Matrix([2 * X - Y, X + 3 * Y])
    assert simplify(T(x1 + x2, y1 + y2) - (T(x1, y1) + T(x2, y2))) == zeros(2, 1)
    assert simplify(T(kk * x1, kk * y1) - kk * T(x1, y1)) == zeros(2, 1)
    return F(sol=["T(u + v) = (2(x₁ + x₂) - (y₁ + y₂), (x₁ + x₂) + 3(y₁ + y₂))",
                  "= T(u) + T(v)", "T(ku) = (2kx₁ - ky₁, kx₁ + 3ky₁) = k(2x₁ - y₁, x₁ + 3y₁) = kT(u)"],
             final=["T is linear"])


def c52():
    T = lambda X, Y: (X + 1, Y)
    assert T(0, 0) == (1, 0) != (0, 0)
    return F(sol=["T(0, 0) = (0 + 1, 0) = (1, 0)"], final=["T(0, 0) = (1, 0)"])


def c53():
    T = lambda X, Y, Z: Matrix([X + 2 * Y, Y - Z, 3 * X + Z])
    A = Matrix.hstack(T(1, 0, 0), T(0, 1, 0), T(0, 0, 1)); assert A == Matrix([[1, 2, 0], [0, 1, -1], [3, 0, 1]])
    v = Matrix([1, -1, 2]); assert A * v == T(1, -1, 2) == Matrix([-1, -3, 5])
    return F(sol=["T(1, 0, 0) = (1, 0, 3)", "T(0, 1, 0) = (2, 1, 0)", "T(0, 0, 1) = (0, -1, 1)", "A = " + M(A),
                  "(1 - 2 + 0, 0 - 1 - 2, 3 + 0 + 2) = (-1, -3, 5)"],
             final=["A = " + M(A), "T(1, -1, 2) = (-1, -3, 5)"])


def c54():
    Tm = Matrix([[1, 2], [0, 1]]); Sm = Matrix([[0, -1], [1, 0]])
    ST, TS = Sm * Tm, Tm * Sm
    assert ST == Matrix([[0, -1], [1, 2]]) and TS == Matrix([[2, -1], [1, 0]])
    assert ST * Matrix([x, y]) == Matrix([-y, x + 2 * y])
    return F(sol=["[T] = " + M(Tm), "[S] = " + M(Sm), "[S∘T] = [S][T]", "= " + M(ST), "= " + M(TS),
                  "S(x + 2y, y) = (-y, x + 2y)"],
             final=["[S∘T] = " + M(ST), "[T∘S] = " + M(TS)])


def c55():
    Rot = Matrix([[0, -1], [1, 0]]); Fx = Matrix([[1, 0], [0, -1]])
    FR = Fx * Rot; assert FR == Matrix([[0, -1], [-1, 0]])
    assert Fx * (Rot * Matrix([1, 0])) == FR[:, 0] == Matrix([0, -1])
    assert FR * Matrix([x, y]) == Matrix([-y, -x])
    # reflection in y = -x : fixes (1,-1), flips (1,1)
    assert FR * Matrix([1, -1]) == Matrix([1, -1]) and FR * Matrix([1, 1]) == -Matrix([1, 1])
    return F(sol=["R = " + M(Rot), "F = " + M(Fx), "= " + M(FR), "(0, 1)", "(0, -1)", "(-y, -x)", "y = -x"],
             final=[M(FR), "y = -x"])


def c56():
    A = Matrix([[1, -1, 2], [2, -2, 5], [1, -1, 3]])
    r = R(A); r.add(2, -2, 1).add(3, -1, 1); f1 = r.mat()
    r.add(3, -1, 2).add(1, -2, 2); f2 = r.mat()
    assert A.rank() == 2 and len(A.nullspace()) == 1
    assert A * Matrix([1, 1, 0]) == zeros(3, 1) and A.nullspace()[0] == Matrix([1, 1, 0])
    cs = A.columnspace(); assert cs[0] == Matrix([1, 2, 1]) and cs[1] == Matrix([2, 5, 3])
    return F(prompt=["A = " + M(A)],
             sol=[f1, f2, "x = s, z = 0", "(1, 1, 0)", "(1, 2, 1), (2, 5, 3)", "2 + 1 = 3"],
             final=["{(1, 1, 0)}", "{(1, 2, 1), (2, 5, 3)}", "rank 2, nullity 1"])


def c57():
    T = lambda X, Y: Matrix([X + Y, X - Y, 2 * X])
    A = Matrix.hstack(T(1, 0), T(0, 1)); assert A == Matrix([[1, 1], [1, -1], [2, 0]])
    assert A.nullspace() == [] and A.rank() == 2
    return F(sol=["[1 1; 1 -1; 2 0]", "x + y = 0, x - y = 0, 2x = 0", "x = 0 and y = 0", "nullity = 0",
                  "rank = 2 - 0 = 2"], final=["One-to-one", "rank 2, nullity 0"])


def c58():
    b1, b2 = Matrix([1, 1]), Matrix([1, 2]); p1, p2 = Matrix([1, 0]), Matrix([1, 1])
    Bp = Matrix.hstack(p1, p2)
    c1 = Bp.inv() * b1; c2 = Bp.inv() * b2
    assert c1 == Matrix([0, 1]) and c2 == Matrix([-1, 2])
    P = Matrix.hstack(c1, c2); assert P == Matrix([[0, -1], [1, 2]])
    cB = Matrix([1, 2]); vB1 = P * cB; assert vB1 == Matrix([-2, 5])
    v = Matrix.hstack(b1, b2) * cB; assert v == Matrix([3, 5]) and Bp * vB1 == v
    return F(sol=["(1, 1) = 0(1, 0) + 1(1, 1)", "(0, 1)", "(1, 2) = -1(1, 0) + 2(1, 1)", "(-1, 2)",
                  "P = " + M(P), "(0(1) - 1(2), 1(1) + 2(2)) = (-2, 5)", "(3, 5)"],
             final=["P = " + M(P), "(-2, 5)"])


def c59():
    Tm = Matrix([[1, 1], [2, 0]])
    b1, b2 = Matrix([1, 1]), Matrix([1, -1]); Bm = Matrix.hstack(b1, b2)
    TB = Bm.inv() * Tm * Bm; assert TB == Matrix([[2, 1], [0, -1]])
    assert Tm * b1 == Matrix([2, 2]) == 2 * b1 and Tm * b2 == Matrix([0, 2]) == b1 - b2
    v = Matrix([3, 1]); vB = Bm.inv() * v; assert vB == Matrix([2, 1])
    TvB = TB * vB; assert TvB == Matrix([5, -1]) and Bm * TvB == Matrix([4, 6]) == Tm * v
    return F(sol=["T(1, 1) = (2, 2)", "(2, 0)", "T(1, -1) = (0, 2)", "(1, -1)", "[T]_B = " + M(TB),
                  "[v]_B = (2, 1)", "(5, -1)", "(4, 6)"],
             final=["[T]_B = " + M(TB), "T(3, 1) = (4, 6)"])


def c60():
    # P2 -> P1, p -> p'
    A = Matrix([[0, 1, 0], [0, 0, 2]])
    p = a + b * x + c * x ** 2
    dp = p.diff(x); assert dp == b + 2 * c * x
    cols = []
    for basis in (S(1), x, x ** 2):
        d_ = basis.diff(x); cols.append([d_.subs(x, 0), d_.coeff(x, 1) if d_ != 0 else 0])
    assert Matrix(cols).T == A
    assert A.rank() == 2 and len(A.nullspace()) == 1 and A.nullspace()[0] == Matrix([1, 0, 0])
    return F(sol=["T(1) = 0, T(x) = 1, T(x²) = 2x", "T(1) = (0, 0), T(x) = (1, 0), T(x²) = (0, 2)", "[0 1 0; 0 0 2]",
                  "b = 0 and 2c = 0", "span{1}", "2 + 1 = 3"],
             final=["[0 1 0; 0 0 2]", "ker T = span{1}", "range = P₁"])


# ----------------------------------------------------------------- topic 9
def c61():
    A = Matrix([[4, 1], [2, 3]])
    cp = (A - lam * eye(2)).det(); eq(cp, lam ** 2 - 7 * lam + 10)
    assert sorted(solve(cp, lam)) == [2, 5] and A.trace() == 7 and A.det() == 10
    return F(prompt=["A = " + M(A)],
             sol=["(4 - λ)(3 - λ) - 1(2)", "λ² - 7λ + 12 - 2 = λ² - 7λ + 10", "(λ - 2)(λ - 5)",
                  "λ = 2 and λ = 5", "trace = 4 + 3 = 7 = 2 + 5", "det = 12 - 2 = 10 = 2 · 5"],
             final=["λ² - 7λ + 10", "2 and 5"])


def c62():
    A = Matrix([[1, 2], [3, 2]])
    cp = (A - lam * eye(2)).det(); eq(cp, (lam - 4) * (lam + 1))
    ev = A.eigenvects(); d = {v: vecs for v, m, vecs in ev}
    assert set(d) == {4, -1}
    assert A * Matrix([2, 3]) == 4 * Matrix([2, 3]) == Matrix([8, 12]) and A * Matrix([1, -1]) == -Matrix([1, -1])
    assert (A - 4 * eye(2)) == Matrix([[-3, 2], [3, -2]]) and (A + eye(2)) == Matrix([[2, 2], [3, 3]])
    return F(prompt=["A = " + M(A)],
             sol=["(1 - λ)(2 - λ) - 6 = λ² - 3λ - 4 = (λ - 4)(λ + 1)", "A - 4I = [-3 2; 3 -2]",
                  "A + I = [2 2; 3 3]", "(2, 3)", "(1, -1)", "A(2, 3) = (8, 12)", "A(1, -1) = (-1, 1)"],
             final=["λ = 4 with (2, 3)", "λ = -1 with (1, -1)"])


def c63():
    A = Matrix([[2, 1, 0], [0, 2, 0], [0, 0, 3]])
    assert A.eigenvals() == {2: 2, 3: 1}
    B = A - 2 * eye(3); assert B == Matrix([[0, 1, 0], [0, 0, 0], [0, 0, 1]]) and B.rank() == 2
    assert len(B.nullspace()) == 1 and not A.is_diagonalizable()
    return F(prompt=["A = " + M(A)],
             sol=["A - 2I = " + M(B), "rank 2", "3 - 2 = 1", "algebraic multiplicity 2", "not diagonalisable"],
             final=["Not diagonalisable"])


def c64():
    A = Matrix([[4, 0, 1], [2, 3, 2], [1, 0, 4]])
    cp = (A - lam * eye(3)).det()
    eq(cp, (3 - lam) * (lam - 3) * (lam - 5)); assert A.eigenvals() == {3: 2, 5: 1}
    B = A - 3 * eye(3); assert B == Matrix([[1, 0, 1], [2, 0, 2], [1, 0, 1]]) and B.rank() == 1 and len(B.nullspace()) == 2
    v1, v2 = Matrix([0, 1, 0]), Matrix([-1, 0, 1])
    assert B * v1 == zeros(3, 1) and B * v2 == zeros(3, 1)
    v5 = Matrix([1, 2, 1]); assert A * v5 == 5 * v5
    assert A.is_diagonalizable()
    eq((4 - lam) ** 2 - 1, (lam - 3) * (lam - 5))
    return F(prompt=["A = " + M(A)],
             sol=["(3 - λ)((4 - λ)² - 1) = (3 - λ)(λ - 3)(λ - 5)", "A - 3I = " + M(B), "3 - 1 = 2",
                  "(0, 1, 0) and (-1, 0, 1)", "(1, 2, 1)", "2 + 1 = 3"],
             final=["3 (twice) and 5", "diagonalisable"])


def c65():
    A = Matrix([[1, 1], [-2, 4]])
    cp = (A - lam * eye(2)).det(); eq(cp, lam ** 2 - 5 * lam + 6)
    assert (A - 2 * eye(2)) == Matrix([[-1, 1], [-2, 2]]) and (A - 3 * eye(2)) == Matrix([[-2, 1], [-2, 1]])
    assert A * Matrix([1, 1]) == 2 * Matrix([1, 1]) and A * Matrix([1, 2]) == 3 * Matrix([1, 2])
    P = Matrix([[1, 1], [1, 2]]); D = diag(2, 3)
    assert P.det() == 1 and P.inv() == Matrix([[2, -1], [-1, 1]]) and P * D * P.inv() == A
    assert A * P == Matrix([[2, 3], [2, 6]]) == P * D
    return F(prompt=["A = " + M(A)],
             sol=["(1 - λ)(4 - λ) + 2 = λ² - 5λ + 6 = (λ - 2)(λ - 3)", "A - 2I = [-1 1; -2 2]",
                  "A - 3I = [-2 1; -2 1]", "(1, 1)", "(1, 2)", "P = [1 1; 1 2] and D = [2 0; 0 3]",
                  "P⁻¹ = [2 -1; -1 1]", "AP = [2 3; 2 6] and PD = [2 3; 2 6]"],
             final=["P = [1 1; 1 2], D = [2 0; 0 3]"])


def c66():
    A = Matrix([[1, 1], [-2, 4]])
    P = Matrix([[1, 1], [1, 2]]); D = diag(2, 3)
    A5 = A ** 5; assert A5 == Matrix([[-179, 211], [-422, 454]]) and P * D ** 5 * P.inv() == A5
    assert D ** 5 == diag(32, 243) and P * D ** 5 == Matrix([[32, 243], [32, 486]])
    assert 64 - 243 == -179 and -32 + 243 == 211 and 64 - 486 == -422 and -32 + 486 == 454
    return F(prompt=["A = " + M(A)],
             sol=["D⁵ = [32 0; 0 243]", "P D⁵ = [32 243; 32 486]", "64 - 243, -32 + 243; 64 - 486, -32 + 486",
                  "A⁵ = " + M(A5)], final=["A⁵ = " + M(A5)])


def c67():
    A = Matrix([[1, 2], [0, 3]]); P = Matrix([[1, 1], [1, 2]])
    assert P.det() == 1 and P.inv() == Matrix([[2, -1], [-1, 1]])
    AP = A * P; assert AP == Matrix([[3, 5], [3, 6]])
    B = P.inv() * AP; assert B == Matrix([[3, 4], [0, 1]])
    cA = (A - lam * eye(2)).det(); cB = (B - lam * eye(2)).det()
    eq(cA, lam ** 2 - 4 * lam + 3); eq(cB, lam ** 2 - 4 * lam + 3)
    assert 2 * 3 - 3 == 3 and 2 * 5 - 6 == 4 and -3 + 3 == 0 and -5 + 6 == 1
    return F(prompt=["A = " + M(A), "P = " + M(P)],
             sol=["P⁻¹ = [2 -1; -1 1]", "AP = [1 + 2, 1 + 4; 3, 6] = " + M(AP),
                  "B = P⁻¹(AP) = [2(3) - 3, 2(5) - 6; -3 + 3, -5 + 6] = " + M(B),
                  "λ² - 4λ + 3", "1 and 3"],
             final=["B = " + M(B), "λ² - 4λ + 3"])


def c68():
    # Concrete 3x3 with eigenvalues 2, -1, 3 (non-diagonal) to confirm the rules
    P = Matrix([[1, 1, 0], [0, 1, 1], [1, 0, 1]]); A = P * diag(2, -1, 3) * P.inv()
    assert sorted(A.eigenvals()) == [-1, 2, 3]
    assert sorted((A ** 2).eigenvals()) == [1, 4, 9]
    assert sorted(A.inv().eigenvals()) == [Rational(-1), Rational(1, 3), Rational(1, 2)]
    assert sorted((A + 4 * eye(3)).eigenvals()) == [3, 6, 7]
    assert A.det() == -6 and A.trace() == 4
    return F(sol=["A²: 4, 1, 9", "A⁻¹: 1/2, -1, 1/3", "A + 4I: 6, 3, 7", "2(-1)(3) = -6", "2 - 1 + 3 = 4"],
             final=["A²: 4, 1, 9", "A⁻¹: 1/2, -1, 1/3", "A + 4I: 6, 3, 7", "det A = -6", "trace A = 4"])


def c69():
    Pm = Matrix([[Rational(8, 10), Rational(3, 10)], [Rational(2, 10), Rational(7, 10)]])
    IM = Pm - eye(2)
    assert IM == Matrix([[Rational(-2, 10), Rational(3, 10)], [Rational(2, 10), Rational(-3, 10)]])
    ns = IM.nullspace()[0]; steady = ns / sum(ns)
    assert steady == Matrix([Rational(6, 10), Rational(4, 10)]) and Pm * steady == steady
    assert Rational(48, 100) + Rational(12, 100) == Rational(6, 10) and Rational(12, 100) + Rational(28, 100) == Rational(4, 10)
    return F(prompt=["0.8 0.3; 0.2 0.7"],
             sol=["[-0.2 0.3; 0.2 -0.3]", "x = 1.5y", "1.5y + y = 1", "y = 0.4 and x = 0.6",
                  "(0.48 + 0.12, 0.12 + 0.28) = (0.6, 0.4)"],
             final=["City 0.6, suburb 0.4"])


CHECKS = {f"la-{i:02d}": fn for i, fn in enumerate(
    [c01, c02, c03, c04, c05, c06, c07, c08, c09, c10, c11, c12, c13, c14, c15, c16, c17, c18, c19, c20, c21,
     c22, c23, c24, c25, c26, c27, c28, c29, c30, c31, c32, c33, c34, c35, c36, c37, c38, c39, c40, c41, c42,
     c43, c44, c45, c46, c47, c48, c49, c50, c51, c52, c53, c54, c55, c56, c57, c58, c59, c60, c61, c62, c63,
     c64, c65, c66, c67, c68, c69], start=1)}

REQUIRED_KEYS = ["id", "source", "prompt_latex", "prompt_plain", "prompt_parts", "worked_solution", "final_answer", "level"]


def main():
    with open(PATH, encoding="utf-8") as fh:
        problems = json.load(fh)
    failures = []
    verified = 0
    seen = set()
    for p in problems:
        pid = p["id"]
        seen.add(pid)
        try:
            assert list(p.keys()) == REQUIRED_KEYS, f"keys {list(p.keys())}"
            assert p["level"] == "college" and p["source"].endswith(", original")
            assert p["prompt_parts"] and all("text" in part for part in p["prompt_parts"])
            assert isinstance(p["worked_solution"], list) and 2 <= len(p["worked_solution"]) <= 12
            assert all(isinstance(l, str) and l.strip() for l in p["worked_solution"])
            assert pid in CHECKS, "no check function"
            facts = CHECKS[pid]()
            texts = {"prompt": norm(p["prompt_plain"]),
                     "sol": norm(" ".join(p["worked_solution"])),
                     "final": norm(p["final_answer"])}
            for where, items in facts.items():
                for item in items:
                    needle = norm(item)
                    assert needle in texts[where], f"{where} text missing fact: {item!r}"
            verified += 1
        except AssertionError as err:
            failures.append((pid, f"AssertionError: {err}"))
        except Exception as err:   # a crash in sympy is a failure too
            failures.append((pid, f"{type(err).__name__}: {err}"))
    missing = sorted(set(CHECKS) - seen)
    for pid in missing:
        failures.append((pid, "check exists but problem is missing from problems.json"))
    print(f"problems in file: {len(problems)}   verified: {verified}   failed: {len(failures)}")
    for pid, msg in failures:
        print(f"  FAIL {pid}: {msg}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
