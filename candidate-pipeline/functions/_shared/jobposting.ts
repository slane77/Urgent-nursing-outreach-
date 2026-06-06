// ============================================================================
//  Day Webster — Candidate Pipeline · shared JobPosting builder
//  Builds Google-for-Jobs structured data (schema.org/JobPosting) from a
//  vacancy row. Used by job-advert (to store it) and jobs (to serve it).
//  Env: PUBLIC_SITE_URL (where intake.html is hosted), ORG_NAME, ORG_URL
// ============================================================================

const EMP: Record<string, string> = {
  full_time: "FULL_TIME", "full time": "FULL_TIME", fulltime: "FULL_TIME",
  part_time: "PART_TIME", "part time": "PART_TIME", parttime: "PART_TIME",
  contract: "CONTRACTOR", contractor: "CONTRACTOR", locum: "CONTRACTOR",
  temporary: "TEMPORARY", temp: "TEMPORARY", bank: "TEMPORARY",
};

export function applyUrl(slug: string): string {
  const site = (Deno.env.get("PUBLIC_SITE_URL") ?? "").replace(/\/$/, "");
  return `${site}/intake.html?vacancy=${encodeURIComponent(slug)}`;
}

// Minimal markdown-ish text -> HTML (Google requires an HTML description).
export function toHtml(text = ""): string {
  const esc = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  return esc.split(/\n{2,}/).map((p) => `<p>${p.replace(/\n/g, "<br>")}</p>`).join("");
}

export function buildJobPosting(v: any, descriptionHtml: string) {
  const jp: any = {
    "@context": "https://schema.org/",
    "@type": "JobPosting",
    title: v.title,
    description: descriptionHtml,
    datePosted: v.date_posted ?? undefined,
    validThrough: v.valid_through ?? undefined,
    employmentType: EMP[(v.employment_type ?? "").toLowerCase()] ?? undefined,
    hiringOrganization: {
      "@type": "Organization",
      name: Deno.env.get("ORG_NAME") ?? "Day Webster",
      sameAs: Deno.env.get("ORG_URL") ?? "https://www.daywebster.com",
    },
    jobLocation: {
      "@type": "Place",
      address: {
        "@type": "PostalAddress",
        addressLocality: v.town || undefined,
        addressRegion: v.region || undefined,
        addressCountry: "GB",
      },
    },
    directApply: true,
    url: applyUrl(v.slug),
  };
  // prune undefined for clean JSON-LD
  return JSON.parse(JSON.stringify(jp));
}
