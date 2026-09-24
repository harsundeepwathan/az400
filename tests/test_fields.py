from jobhunter.apply.fields import Field, best_option, resolve

CFG = {
    "personal": {"first_name": "Jane", "last_name": "Doe", "email": "j@x.com", "phone": "1", "linkedin": "https://li"},
    "answers": {"work_authorization": "Yes", "require_sponsorship": "No", "years_experience": 6,
                "custom": [{"match": "why .*join", "answer": "Because."}], "eeo": {}},
}


def r(kind, label, options=(), required=False):
    return resolve(Field(id="f", kind=kind, label=label, options=list(options), required=required), CFG, "/cv.pdf", None, "")


def test_personal():
    assert r("text", "First name *").value == "Jane"
    assert r("text", "Last Name").value == "Doe"
    assert r("email", "Email address").value == "j@x.com"
    assert r("url", "LinkedIn Profile").value == "https://li"
    assert r("file", "Resume/CV").value == "/cv.pdf"


def test_screening():
    assert r("radio", "Are you legally authorized to work in Canada?", ["Yes", "No"]).value == "Yes"
    assert r("radio", "Will you require visa sponsorship?", ["Yes", "No"]).value == "No"
    assert r("select", "Years of experience", ["Select...", "0-2", "3-5", "6+ years"]).value == "6+ years"
    assert r("textarea", "Why do you want to join us?").value == "Because."


def test_eeo_and_consent():
    assert r("select", "Gender", ["Male", "Female", "I don't wish to answer"]).value == "I don't wish to answer"
    assert r("checkbox", "I agree to the privacy policy *", ["I agree to the privacy policy"], required=True).value is True
    assert r("checkbox", "I consent to be contacted about future jobs", ["x"]).value is False


def test_name_rules():
    assert r("text", "Full name *").value == "Jane Doe"
    assert r("text", "Name Pronunciation | How do you pronounce your name?") is None


def test_skill_specific_years_not_answered_with_total():
    assert r("select", "Years of experience with Kubernetes", ["0-2", "3-5", "6+ years"]) is None


def test_unknown_goes_unresolved():
    assert r("text", "What is your favourite Kubernetes operator?") is None


def test_best_option_ranges():
    assert best_option(["Less than 1 year", "1-3 years", "4-6 years", "7+ years"], "5") == "4-6 years"
    assert best_option(["Less than 1 year", "1-3 years", "7+ years"], "9") == "7+ years"
