from unittest import TestCase

from scripts.audit_outcome_witnesses import preparation_diagnosis


class PreparationDiagnosisTest(TestCase):
    def setUp(self):
        self.producer = dict(
            event="p",
            ordinal=3,
            context="before",
            after="after",
            attempt=1,
            level=0,
            state="NOT_FINISHED",
            advanced=False,
            prior=None,
            complete=True,
            residual=0,
            producer="load",
            available={1, 2},
        )
        self.result = dict(
            prior="p",
            context="after",
            action=(2,),
            appearance=None,
            attempt=1,
            level=0,
            available={1, 2},
        )

    def diagnose(self, comparisons=()):
        return preparation_diagnosis(
            self.result,
            {"p": self.producer},
            {("before", (2,)): comparisons},
        )

    def test_separates_unknown_effect_and_missing_producer(self):
        self.producer.update(complete=False, residual=4, producer=None)
        result = self.diagnose()
        self.assertEqual(result["stop"], "local_effect_uncertain")
        self.assertEqual(result["also_missing"], ["missing_producer"])

    def test_witness_requires_earlier_comparable_failure_to_advance(self):
        comparison = dict(
            ordinal=4,
            state="NOT_FINISHED",
            advanced=False,
            appearance=None,
            event="contrast",
        )
        self.assertEqual(self.diagnose([comparison])["stop"], "missing_comparison")
        comparison["ordinal"] = 2
        self.assertEqual(self.diagnose([comparison])["comparison"], "contrast")
        self.producer["attempt"] = 2
        self.assertEqual(self.diagnose([comparison])["stop"], "scope_boundary")
