import path from "node:path";
import { expect, test, type Page } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";

const password = "correct-horse-battery";

async function expectNoSeriousA11yIssues(page: Page) {
  const results = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa"]).analyze();
  const serious = results.violations.filter((v) => v.impact === "serious" || v.impact === "critical");
  expect(serious.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(" ")).join(", ")}`)).toEqual([]);
}

test.describe("principal workflow", () => {

  test("sign up, onboard, add resume, analyse a job, track an application", async ({ page }) => {
    const email = `e2e-${Date.now()}@test.local`;

    // Protected routes redirect to sign-in.
    await page.goto("/today");
    await expect(page).toHaveURL(/\/sign-in\?next=%2Ftoday/);

    // Create an account, sign out, then sign in.
    await page.goto("/sign-up");
    await page.getByLabel("Email").fill(email);
    await page.getByLabel("Password").fill(password);
    await page.getByRole("button", { name: "Create account" }).click();
    await expect(page).toHaveURL(/\/onboarding/);
    await page.context().clearCookies();
    await page.goto("/sign-in");
    await page.getByLabel("Email").fill(email);
    await page.getByLabel("Password").fill("wrong-password-123");
    await page.getByRole("button", { name: "Sign in" }).click();
    await expect(page.getByRole("alert").filter({ hasText: "Incorrect email or password" })).toBeVisible();
    await page.getByLabel("Password").fill(password);
    await page.getByRole("button", { name: "Sign in" }).click();

    // Onboarding (the app layout redirects here until it is complete).
    await expect(page).toHaveURL(/\/onboarding/);
    await expectNoSeriousA11yIssues(page);
    await page.getByLabel("Full name").fill("Casey Tester");
    await page.getByLabel("Current or most recent role").fill("Senior Platform Engineer");
    await page.getByLabel("Target job titles").fill("Platform Engineer\nSite Reliability Engineer");
    await page.getByLabel("Preferred locations").fill("London\nRemote");
    await page.getByLabel("Target salary (annual)").fill("95000");
    await page.getByLabel("Currency").fill("GBP");
    await page.getByRole("button", { name: "Save and continue" }).click();
    await expect(page).toHaveURL(/\/today/);
    await expect(page.getByText("Step 2 of 2")).toBeVisible();

    // Upload a PDF resume, review the structured preview, save.
    await page.getByRole("link", { name: "Add resume" }).first().click();
    await page.locator("#resume-file").setInputFiles(path.join(__dirname, "..", "fixtures", "sample-resume.pdf"));
    await page.getByRole("button", { name: "Extract and preview" }).click();
    await expect(page.getByText("Review before saving")).toBeVisible();
    await expect(page.getByLabel("Job title").first()).toHaveValue("Senior Platform Engineer");
    await expect(page.getByLabel("Employer").first()).toHaveValue("Northwind Payments");
    await page.getByLabel("Resume name").fill("E2E resume");
    await page.getByRole("button", { name: "Save resume" }).click();
    await expect(page).toHaveURL(/\/resumes\/[0-9a-f-]+\?saved=1/);
    await expect(page.getByText("Resume saved")).toBeVisible();

    // Import achievements into the evidence vault.
    await page.getByRole("button", { name: "Import achievements as evidence" }).click();
    await expect(page.getByText(/Imported \d+ achievements?/)).toBeVisible();

    // Save a job.
    await page.goto("/jobs/new");
    await page.getByLabel("Job title").fill("Platform Engineer");
    await page.getByLabel("Company").fill("Acme Cloud");
    await page.getByLabel("Location").fill("London");
    await page.getByLabel("Workplace").selectOption("hybrid");
    await page.getByLabel("Where you found it").fill("LinkedIn");
    await page.getByLabel("Job description", { exact: true }).fill(
      "Requirements:\n- 5+ years of platform engineering experience\n- Kubernetes and Terraform\n- Experience with Rust\n\nNice to have:\n- Prometheus and Grafana",
    );
    await page.getByRole("button", { name: "Save job" }).click();
    await expect(page).toHaveURL(/\/jobs\/[0-9a-f-]+\?saved=1/);
    await expect(page.getByRole("listitem").filter({ hasText: "Kubernetes and Terraform" })).toBeVisible();

    // Run the fit analysis with the mock provider.
    await page.getByRole("button", { name: "Run fit analysis" }).click();
    await expect(page.getByText("Evidence-matching score")).toBeVisible();
    await expect(page.getByText("Demo output (mock AI)")).toBeVisible();
    await expect(page.getByText(/does not predict how an\s+applicant-tracking system/)).toBeVisible();
    await expect(page.getByRole("heading", { name: /Missing requirements/ })).toBeVisible();
    await expect(page.getByText("Experience with Rust").first()).toBeVisible();
    await expectNoSeriousA11yIssues(page);

    // Create the application and draft materials.
    await page.getByRole("button", { name: "Start application" }).click();
    await expect(page).toHaveURL(/\/applications\/[0-9a-f-]+$/);
    await page.getByRole("button", { name: "Draft materials" }).click();
    const coverLetter = page.getByLabel("Cover letter draft", { exact: true });
    await expect(coverLetter).toHaveValue(/Dear Hiring Manager/);
    await expect(coverLetter).toHaveValue(/Acme Cloud/);
    // The missing requirement is acknowledged as a gap, never claimed as experience.
    await expect(coverLetter).toHaveValue(/the role also asks for Experience with Rust/);
    await expect(coverLetter).not.toHaveValue(/I have (experience|expertise) (with|in) Rust/i);
    await expectNoSeriousA11yIssues(page);

    // Move it to Applied on the board.
    await page.goto("/applications");
    await page.waitForLoadState("networkidle");
    const card = page.getByTestId(/app-card-/).first();
    await card.getByRole("combobox").selectOption("applied");
    await expect(page.getByTestId("column-applied").getByRole("link", { name: "Platform Engineer", exact: true })).toBeVisible();
    await page.reload();
    await expect(page.getByTestId("column-applied").getByRole("link", { name: "Platform Engineer", exact: true })).toBeVisible();

    // Dashboard reflects the new state: a follow-up reminder and weekly progress.
    await page.goto("/today");
    await expect(page.getByText("1 of 5 goal")).toBeVisible();
    await page.goto("/reminders");
    await expect(page.getByText("Follow up on your Acme Cloud application")).toBeVisible();

    // Analytics are calculated from the recorded events.
    await page.goto("/analytics");
    await expect(page.getByText("Small sample")).toBeVisible();
    await expect(page.getByText("You have 1 submitted application.")).toBeVisible();
    await expect(page.getByText("Too few to conclude").first()).toBeVisible();
    await expectNoSeriousA11yIssues(page);

    // Status history is recorded.
    await page.goto("/applications?view=list");
    await page.getByRole("link", { name: "Platform Engineer" }).click();
    await expect(page.getByText(/Interested → Applied/)).toBeVisible();

    // Another account cannot open this application.
    const appUrl = page.url();
    await page.context().clearCookies();
    await page.goto("/sign-in");
    await page.getByLabel("Email").fill("demo@jobpilot.local");
    await page.getByLabel("Password").fill("demo-password-123");
    await page.getByRole("button", { name: "Sign in" }).click();
    await expect(page).toHaveURL(/\/today/);
    await page.goto(appUrl);
    await expect(page.getByRole("heading", { name: "Page not found" })).toBeVisible();
    await expect(page.getByText("Acme Cloud")).toHaveCount(0);
  });
});

test.describe("demo account", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/sign-in");
    await page.getByLabel("Email").fill("demo@jobpilot.local");
    await page.getByLabel("Password").fill("demo-password-123");
    await page.getByRole("button", { name: "Sign in" }).click();
    await expect(page).toHaveURL(/\/today/);
  });

  test("key pages render without errors or horizontal overflow", async ({ page, isMobile }) => {
    await page.goto("/applications?view=list");
    const appHref = await page.getByRole("link", { name: "Senior Platform Engineer" }).getAttribute("href");
    await page.goto("/jobs");
    const jobHref = await page.getByRole("link", { name: "Senior Platform Engineer" }).getAttribute("href");
    await page.goto("/resumes");
    const resumeHref = await page.getByRole("link", { name: /Platform engineering resume/ }).getAttribute("href");
    const versionHref = await page.getByRole("link", { name: "Platform roles — general" }).getAttribute("href");
    const pages = [
      "/today", "/jobs", "/jobs/new", jobHref!, "/applications", "/applications?view=list", appHref!, `${appHref}/interview`,
      "/resumes", "/resumes/new", resumeHref!, versionHref!, "/evidence", "/evidence/new", "/interviews", "/analytics", "/reminders", "/settings",
    ];
    for (const url of pages) {
      await page.goto(url);
      await expect(page.locator("h1").first()).toBeVisible();
      await expect(page.getByText("Something went wrong"), `${url} rendered an error`).toHaveCount(0);
      if (isMobile) {
        // The board scrolls inside its own container; the page itself must not.
        const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
        expect(overflow, `${url} overflows horizontally`).toBeLessThanOrEqual(1);
      }
    }
  });

  test("today shows at most three priorities from real state", async ({ page }) => {
    const priorities = page.getByRole("heading", { name: "Top priorities" }).locator("..").getByRole("listitem");
    const count = await priorities.count();
    expect(count).toBeGreaterThan(0);
    expect(count).toBeLessThanOrEqual(3);
    await expect(page.getByText("Prepare for your Brightline Health interview").first()).toBeVisible();
  });

  test("mobile navigation works", async ({ page, isMobile }) => {
    test.skip(!isMobile, "mobile only");
    await page.getByRole("button", { name: "Open menu" }).click();
    await page.getByRole("navigation", { name: "Main" }).getByRole("link", { name: "Analytics" }).click();
    await expect(page).toHaveURL(/\/analytics/);
    await expect(page.getByRole("heading", { name: "Analytics" })).toBeVisible();
  });
});
