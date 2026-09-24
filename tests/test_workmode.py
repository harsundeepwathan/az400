from jobhunter.models import Job, WorkMode
from jobhunter.workmode import classify, from_label, location_ok


def job(loc, mode):
    return Job(source="t", ats="t", company="c", external_id="1", title="Engineer", url="", location=loc, work_mode=mode)


def test_labels():
    assert from_label("OnSite") == WorkMode.ONSITE
    assert from_label("on_site") == WorkMode.ONSITE
    assert from_label("Hybrid") == WorkMode.HYBRID
    assert from_label("remote") == WorkMode.REMOTE
    assert from_label("unspecified") == WorkMode.UNKNOWN


def test_classify_from_location_and_text():
    assert classify("Remote - US") == WorkMode.REMOTE
    assert classify("London (Hybrid)") == WorkMode.HYBRID
    assert classify("Berlin", "This is a hybrid role with 3 days per week in office") == WorkMode.HYBRID
    assert classify("Paris", "Great team.") == WorkMode.ONSITE
    assert classify("", "") == WorkMode.UNKNOWN


def test_location_filters():
    s = {"work_modes": ["remote", "hybrid"], "locations": ["Toronto", "Canada"], "remote_regions": ["worldwide", "north america"]}
    assert location_ok(job("Remote", WorkMode.REMOTE), s)[0]
    assert location_ok(job("Remote - North America", WorkMode.REMOTE), s)[0]
    assert location_ok(job("Remote, Canada", WorkMode.REMOTE), s)[0]
    assert not location_ok(job("Remote - Germany", WorkMode.REMOTE), s)[0]
    assert location_ok(job("Toronto, ON", WorkMode.HYBRID), s)[0]
    assert not location_ok(job("New York", WorkMode.HYBRID), s)[0]
    assert not location_ok(job("Toronto", WorkMode.ONSITE), s)[0]  # onsite not wanted
