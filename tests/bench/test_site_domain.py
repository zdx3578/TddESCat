"""Count the independently replayed bindings, including reopened observations."""

from copy import deepcopy
from unittest import TestCase

from tests.bench.autonomous_audit import CONTACT_DOMAIN, SiteDomain, audit_site_facts


class SiteDomainTest(TestCase):
    def setUp(self):
        self.frame = [[0] * 30 for _ in range(22)]
        for x in (4, 12):
            for y in range(4, 10):
                for col in range(x - 2, x + 4):
                    self.frame[y][col] = (
                        7 if y in (4, 9) or col in (x - 2, x + 3) else 0
                    )
            for col, y in ((x, 6), (x + 1, 6), (x, 7)):
                self.frame[y][col] = 2
        for x, y in ((21, 6), (22, 6), (21, 7)):
            self.frame[y][x] = 3
        self.role = [(u, v, 9) for u in range(2) for v in range(2)]
        for u, v, ink in self.role:
            self.frame[16 + v][4 + u] = ink
        self.survey = dict(event="e0", origin=[4, 16], role=self.role, stride=[2, 2])
        self.receipts = {"e0": dict(levels_completed=0, frame=[self.frame])}

    def test_missing_repeated_wrong_and_reopened(self):
        domain = SiteDomain()
        domain.observe([self.survey], self.receipts, 0)
        self.assertEqual(set(domain.remaining()), {(4, 6), (12, 6)})
        facts = dict(
            remaining=[[list(p), site] for p, site in domain.remaining().items()],
            previous_action=1,
            domain_version=CONTACT_DOMAIN,
        )
        self.assertEqual(
            audit_site_facts(
                facts, self.receipts, 0, self.role, domain=domain.remaining()
            ),
            {(4, 6), (12, 6)},
        )
        for misstated, reason in (
            (facts["remaining"][:1], "incomplete_or_substituted_site_domain"),
            ([facts["remaining"][0]] * 2, "repeated_site_binding"),
        ):
            with self.assertRaisesRegex(ValueError, reason):
                audit_site_facts(
                    dict(facts, remaining=misstated),
                    self.receipts,
                    0,
                    self.role,
                    domain=domain.remaining(),
                )
        with self.assertRaisesRegex(ValueError, "site_instance"):
            audit_site_facts(
                facts, self.receipts, 1, self.role, domain=domain.remaining()
            )
        domain.entered(dict(point=[4, 6], outcome="entered", event="e0"))
        self.assertEqual(set(domain.remaining()), {(12, 6)})
        with self.assertRaisesRegex(
            ValueError, "incomplete_or_substituted_site_domain"
        ):
            audit_site_facts(
                facts, self.receipts, 0, self.role, domain=domain.remaining()
            )
        domain.observe([self.survey], self.receipts, 0)
        self.assertNotIn((4, 6), domain.remaining())
        changed = deepcopy(self.frame)
        for x, y in ((4, 6), (5, 6), (4, 7)):
            changed[y][x] = 5
        self.receipts["e1"] = dict(levels_completed=0, frame=[changed])
        domain.observe([dict(self.survey, event="e1")], self.receipts, 0)
        self.assertEqual(set(domain.remaining()), {(4, 6), (12, 6)})
        self.assertEqual(domain.remaining()[(4, 6)]["event"], "e1")
        domain.entered(dict(point=[4, 6], outcome="entered", event="e1"))
        erased = deepcopy(changed)
        for x, y in ((4, 6), (5, 6), (4, 7)):
            erased[y][x] = 0
        self.receipts["e2"] = dict(levels_completed=0, frame=[erased])
        self.receipts["e3"] = dict(levels_completed=0, frame=[changed])
        domain.observe([dict(self.survey, event="e2")], self.receipts, 0)
        self.assertNotIn((4, 6), domain.remaining())
        domain.observe([dict(self.survey, event="e3")], self.receipts, 0)
        self.assertEqual(domain.remaining()[(4, 6)]["event"], "e3")
