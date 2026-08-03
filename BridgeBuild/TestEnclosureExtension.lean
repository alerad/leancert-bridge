/-
Copyright (c) 2026 LeanCert Contributors. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import LeanCert.Tactic.Extension

/-! Generic downstream fixture for Bridge extension-profile integration tests. -/

namespace LeanCert.Bridge.TestEnclosureExtension

open LeanCert.Core LeanCert.Tactic.Extension

def shifted (x : ℝ) : ℝ := x + 1

def shiftedCandidate (request : UnaryEnclosureRequest) :
    Except EnclosureCandidateFailure IntervalRat :=
  .ok <| IntervalRat.add request.input (IntervalRat.singleton 1)

def checkShifted (request : UnaryEnclosureRequest) (output : IntervalRat) : Bool :=
  decide (output = IntervalRat.add request.input (IntervalRat.singleton 1))

@[leancert_enclosure shiftedCandidate, priority := 1200]
theorem shifted_mem
    {request : UnaryEnclosureRequest} {x : ℝ} {output : IntervalRat}
    (hx : x ∈ request.input)
    (hcheck : checkShifted request output = true) :
    shifted x ∈ output := by
  have hout : output = IntervalRat.add request.input (IntervalRat.singleton 1) := by
    exact of_decide_eq_true hcheck
  rw [hout]
  simpa [shifted] using IntervalRat.mem_add hx (IntervalRat.mem_singleton 1)

end LeanCert.Bridge.TestEnclosureExtension
