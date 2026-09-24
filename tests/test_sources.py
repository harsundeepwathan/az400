from jobhunter.models import WorkMode
from jobhunter.sources import ashby, greenhouse, lever, workable
from jobhunter.sources.detect import detect_ats


def test_greenhouse_parse():
    data = {"jobs": [{"id": 1, "title": "SRE", "absolute_url": "https://job-boards.greenhouse.io/acme/jobs/1",
                      "location": {"name": "Remote, Canada"}, "content": "&lt;p&gt;Kubernetes&lt;/p&gt;",
                      "first_published": "2026-09-01T00:00:00Z"}]}
    [j] = greenhouse.parse("acme", data)
    assert j.work_mode == WorkMode.REMOTE and j.description == "Kubernetes" and j.uid == "greenhouse:acme:1"


def test_greenhouse_location_from_offices():
    data = {"jobs": [{"id": 2, "title": "SRE", "absolute_url": "u", "location": {"name": "Hybrid"},
                      "offices": [{"name": "Austin", "location": "Austin, TX, United States"}],
                      "metadata": [{"name": "Job Posting Location", "value": ["Austin, US", "New York, US"]}]}]}
    [j] = greenhouse.parse("acme", data)
    assert j.work_mode == WorkMode.HYBRID and "New York" in j.location and "Austin, TX" in j.location


def test_lever_parse_workplace_type():
    [j] = lever.parse("acme", [{"id": "abc", "text": "DevOps", "hostedUrl": "https://jobs.lever.co/acme/abc",
                                "applyUrl": "https://jobs.lever.co/acme/abc/apply", "workplaceType": "hybrid",
                                "categories": {"location": "Toronto"}, "createdAt": 1790000000000}])
    assert j.work_mode == WorkMode.HYBRID and j.apply_url.endswith("/apply")


def test_ashby_parse():
    [j] = ashby.parse("acme", {"jobs": [{"id": "x", "title": "Eng", "jobUrl": "https://jobs.ashbyhq.com/acme/x",
                                         "workplaceType": "OnSite", "location": "NYC", "isListed": True}]})
    assert j.work_mode == WorkMode.ONSITE and j.apply_url.endswith("/application")


def test_workable_parsers():
    [j] = workable.parse_v3("acme", [{"shortcode": "ABC123", "title": "Platform Engineer", "workplace": "hybrid",
                                      "location": {"city": "Toronto", "country": "Canada"}, "published": "2026-09-01T00:00:00Z"}])
    assert j.work_mode == WorkMode.HYBRID and j.apply_url == "https://apply.workable.com/acme/j/ABC123/apply/"
    [k] = workable.parse_widget("acme", {"jobs": [{"shortcode": "Z9", "title": "SRE", "telecommuting": True, "country": "US"}]})
    assert k.work_mode == WorkMode.REMOTE


def test_detect_ats():
    assert detect_ats("https://apply.workable.com/acme/j/ABC123/") == ("workable", "acme", "ABC123")
    assert detect_ats("https://job-boards.greenhouse.io/stripe/jobs/123") == ("greenhouse", "stripe", "123")
    assert detect_ats("https://jobs.lever.co/palantir/0f1e2d3c-1111-2222-3333-444455556666/apply")[0] == "lever"
    assert detect_ats("https://example.com/careers") == (None, None, None)
