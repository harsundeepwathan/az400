// Keyword normalisation shared by the heuristic matcher and claim checks.

const STOPWORDS = new Set(
  `a an and or the of to in on for with at by from as is are be been being this that these those it its our your you we they
  their them us will would should could can may might must shall have has had do does did not no yes if then than so such
  into over under about across within without per via etc eg ie e.g i.e including include includes plus also well other
  experience experienced years year yrs strong solid proven good great excellent deep broad hands-on hands handson working work
  knowledge understanding ability able skills skill familiarity familiar proficiency proficient using use used demonstrated
  track record background exposure similar related relevant equivalent practical professional environment environments
  role roles team teams preferred required requirement requirements nice have bonus ideally minimum least desirable essential
  plus+ new more most least highly high level levels based field fields degree areas area etc. who what which where when
  engineer engineering practice practices one two three four five six seven eight nine ten 1 2 3 4 5 6 7 8 9 10 11 12 15 20 +`.split(/\s+/),
);

/** Multi-word terms kept as a single token. */
const PHRASES: Array<[RegExp, string]> = [
  [/\bci\s*\/\s*cd\b|\bcontinuous (integration|delivery|deployment)\b/g, "cicd"],
  [/\bmachine learning\b|\bml\b/g, "machine-learning"],
  [/\bartificial intelligence\b/g, "ai"],
  [/\bproject management\b/g, "project-management"],
  [/\bproduct management\b/g, "product-management"],
  [/\bstakeholder management\b/g, "stakeholder-management"],
  [/\bgithub actions\b/g, "github-actions"],
  [/\bgitlab ci\b/g, "gitlab-ci"],
  [/\bazure devops\b/g, "azure-devops"],
  [/\bgoogle cloud( platform)?\b|\bgcp\b/g, "gcp"],
  [/\bamazon web services\b/g, "aws"],
  [/\bmicrosoft azure\b/g, "azure"],
  [/\binfrastructure as code\b|\biac\b/g, "infrastructure-as-code"],
  [/\bsite reliability( engineering)?\b|\bsre\b/g, "sre"],
  [/\bdata analysis\b|\bdata analytics\b/g, "data-analysis"],
  [/\bnode\.?js\b/g, "nodejs"],
  [/\bnext\.?js\b/g, "nextjs"],
  [/\breact\.?js\b/g, "react"],
  [/\bvue\.?js\b/g, "vue"],
  [/\bc\+\+/g, "cpp"],
  [/\bc#/g, "csharp"],
  [/\b\.net\b/g, "dotnet"],
  [/\bon[- ]call\b/g, "on-call"],
  [/\bpeople management\b|\bline management\b|\bmanaging (engineers|people|a team)\b|\bmentor(ed|ing)?\b/g, "people-management"],
  [/\bbachelor'?s?\b|\bb\.?sc\.?\b|\bb\.?a\.?\b(?=\s)|\bb\.?eng\b|\bundergraduate degree\b/g, "bachelor"],
  [/\bmaster'?s?\b|\bm\.?sc\.?\b|\bm\.?eng\b|\bmba\b/g, "master"],
  [/\bph\.?d\.?\b|\bdoctorate\b/g, "phd"],
  [/\bcomputer science\b|\bcs degree\b/g, "computer-science"],
];

const SYNONYMS: Record<string, string> = {
  k8s: "kubernetes",
  eks: "kubernetes",
  aks: "kubernetes",
  gke: "kubernetes",
  postgres: "postgresql",
  psql: "postgresql",
  js: "javascript",
  ts: "typescript",
  golang: "go",
  py: "python",
  mentoring: "people-management",
  coaching: "people-management",
  dashboards: "dashboard",
  apis: "api",
  microservice: "microservices",
  containers: "docker",
  containerisation: "docker",
  containerization: "docker",
  monitoring: "observability",
  analytics: "data-analysis",
  automating: "automation",
  automated: "automation",
  automate: "automation",
  leading: "leadership",
  led: "leadership",
  lead: "leadership",
};

/** Skill families used to recognise transferable (not identical) experience. */
export const FAMILIES: Record<string, string[]> = {
  "cloud platforms": ["aws", "azure", "gcp", "oci"],
  "container orchestration": ["kubernetes", "openshift", "nomad", "ecs"],
  "infrastructure as code": ["terraform", "cloudformation", "pulumi", "bicep", "ansible", "infrastructure-as-code"],
  "CI/CD tooling": ["jenkins", "github-actions", "gitlab-ci", "circleci", "azure-devops", "cicd", "teamcity"],
  "observability tooling": ["prometheus", "grafana", "datadog", "splunk", "newrelic", "opentelemetry", "observability"],
  "relational databases": ["postgresql", "mysql", "sql", "oracle", "mssql", "mariadb"],
  "frontend frameworks": ["react", "vue", "angular", "svelte", "nextjs"],
  "data warehousing": ["snowflake", "bigquery", "redshift", "databricks"],
};

export function normaliseText(text: string): string {
  let t = ` ${text.toLowerCase()} `;
  for (const [re, token] of PHRASES) t = t.replace(re, ` ${token} `);
  return t;
}

let protectedTokens: Set<string> | undefined;
function isProtected(token: string): boolean {
  protectedTokens ??= new Set([...Object.values(FAMILIES).flat(), ...Object.values(SYNONYMS)]);
  return protectedTokens.has(token);
}

/** Light suffix stripping so "engineering"/"engineer" and "systems"/"system" match. */
export function stem(token: string): string {
  if (token.length <= 4 || isProtected(token) || /[^a-z]/.test(token)) return token;
  if (token.endsWith("ing") && token.length > 6) return token.slice(0, -3);
  if (token.endsWith("ies") && token.length > 5) return `${token.slice(0, -3)}y`;
  if (token.endsWith("ed") && token.length > 5) return token.slice(0, -2);
  if (token.endsWith("s") && !token.endsWith("ss") && !token.endsWith("us")) return token.slice(0, -1);
  return token;
}

export function keywords(text: string): Set<string> {
  const out = new Set<string>();
  for (const raw of normaliseText(text).match(/[a-z0-9][a-z0-9+#.\/-]*/g) ?? []) {
    const token = raw.replace(/[.\/-]+$/, "");
    if (token.length < 2 && token !== "r" && token !== "c") continue;
    if (STOPWORDS.has(token) || /^\d+$/.test(token)) continue;
    const canonical = SYNONYMS[token] ?? token;
    const stemmed = stem(canonical);
    if (STOPWORDS.has(stemmed)) continue;
    out.add(stemmed);
  }
  return out;
}

export function familyOf(token: string): string | null {
  for (const [family, members] of Object.entries(FAMILIES)) if (members.includes(token)) return family;
  return null;
}

/** Years of experience demanded by a requirement line, if stated. */
export function requiredYears(text: string): number | null {
  const m = text.match(/(\d{1,2})\s*\+?\s*(?:or more\s+|plus\s+)?(?:years|yrs)/i);
  return m ? Number(m[1]) : null;
}
