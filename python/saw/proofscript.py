from abc import ABCMeta, abstractmethod
from typing import Any, List

class Prover(metaclass=ABCMeta):
  @abstractmethod
  def to_json(self) -> Any: pass

class ABC(Prover):
  def to_json(self) -> Any:
    return { "name": "abc" }

class RME(Prover):
  def to_json(self) -> Any:
    return { "name": "rme" }

class UnintProver(Prover):
  def __init__(self, name : str, unints : List[str]):
    self.name = name
    self.unints = unints

  def to_json(self) -> Any:
    return { "name": self.name, "uninterpreted functions": self.unints }

class CVC4(UnintProver):
  def __init__(self, unints : List[str]):
    super.__init(self, "cvc4", unints)

class Yices(UnintProver):
  def __init__(self, unints : List[str]):
    super.__init(self, "yices", unints)

class Z3(UnintProver):
  def __init__(self, unints : List[str]):
    super.__init(self, "z3", unints)

class ProofTactic(metaclass=ABCMeta):
  @abstractmethod
  def to_json(self) -> Any: pass

class UseProver(ProofTactic):
  def __init__(self, prover : Prover) -> Any:
    self.prover = prover

  def to_json(self) -> Any:
    # TODO: why do we need to pass in self.prover below?
    return { "tactic": "use prover", "prover": self.prover.to_json(self.prover) }

class Unfold(ProofTactic):
  def __init__(self, names : List[str]) -> Any:
    self.names = names

  def to_json(self) -> Any:
    return { "tactic": "unfold", "names": self.names }

class EvaluateGoal(ProofTactic):
  def __init__(self, names : List[str]) -> Any:
    self.names = names

  def to_json(self) -> Any:
    return { "tactic": "evaluate goal", "names": self.names }

# TODO: add "simplify"

class AssumeUnsat(ProofTactic):
  def to_json(self) -> Any:
    return { "tactic": "assume unsat" }

class BetaReduceGoal(ProofTactic):
  def to_json(self) -> Any:
    return { "tactic": "beta reduce goal" }

class Trivial(ProofTactic):
  def to_json(self) -> Any:
    return { "tactic": "trivial" }

class ProofScript:
  def __init__(self, tactics : List[ProofTactic]) -> None:
    self.tactics = tactics

  def to_json(self) -> Any:
    return { 'tactics': [t.to_json() for t in self.tactics] }

abc = UseProver(ABC)
rme = UseProver(RME)

def cvc4(unints : List[str]):
  return UseProver(CVC4(unints))

def yices(unints : List[str]):
  return UseProver(Yices(unints))

def z3(unints : List[str]):
  return UseProver(Z3(unints))
