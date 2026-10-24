async (page) => {
  const base = "http://127.0.0.1:4179";
  await page.route("**/*", (route) =>
    route.request().url().startsWith(base) ? route.continue() : route.abort("internetdisconnected"));
  const response = await page.request.get(`${base}/Fixtures/reading-polish.md`);
  if (!response.ok()) throw new Error("Focused reading fixture is missing");
  const markdown = await response.text();
  await page.goto(`${base}/Web/index.html`);
  await page.setViewportSize({ width: 402, height: 874 });
  await page.evaluate((markdown) =>
    window.gistpadPreview.render({ version: 1, documentID: "reading-polish", generation: "1", markdown }), markdown);
  await page.waitForFunction(() => document.querySelectorAll(".diagram-scroll svg").length === 2);
  const initial = await page.evaluate(() => {
    const current = document.querySelector(".calculation-current");
    const previous = document.querySelector(".calculation-previous");
    const currentStyle = getComputedStyle(current);
    const previousStyle = getComputedStyle(previous);
    const cells = [...document.querySelectorAll("td, th")];
    const summary = document.querySelector("summary");
    const summaryStyle = getComputedStyle(summary);
    const chevron = getComputedStyle(summary, "::before");
    return {
      exactValues: [...document.querySelectorAll(".calculation-result")].map((node) => node.textContent).join("|") === "$15.00|$15.00|$17.00",
      resultNames: current.getAttribute("aria-label") === "Current result: $15.00" &&
        previous.getAttribute("aria-label") === "Previous result: $15.00",
      resultWeight: currentStyle.fontWeight === "600" && previousStyle.fontWeight === "400",
      resultShape: currentStyle.borderRadius === "6px" && currentStyle.padding === "2px 4px",
      resultCopyBehavior: [currentStyle, previousStyle].every((style) => style.userSelect === "none"),
      tabularResults: currentStyle.fontVariantNumeric.includes("tabular-nums"),
      quietTable: cells.every((node) => {
        const style = getComputedStyle(node);
        return style.borderLeftWidth === "0px" && style.borderRightWidth === "0px" &&
          style.borderTopWidth === "0px" && style.borderBottomWidth === "0px" &&
          style.backgroundColor === "rgba(0, 0, 0, 0)";
      }),
      tableHeader: [...document.querySelectorAll("th")].every((node) => getComputedStyle(node).fontWeight === "600"),
      tableAlignment: [...document.querySelectorAll("table:first-child th")].slice(0, 3)
        .map((node) => getComputedStyle(node).textAlign).join("|") === "left|center|right",
      horizontalRules: parseFloat(getComputedStyle(document.querySelector("thead tr")).borderBottomWidth) > 0 &&
        getComputedStyle(document.querySelector("tbody tr:last-child")).borderBottomWidth === "0px",
      localTableScroll: [...document.querySelectorAll(".table-scroll")].some((node) => node.scrollWidth > node.clientWidth + 100),
      unbrokenHeaders: [...document.querySelectorAll("table")[1].querySelectorAll("th")].every((cell) => {
        const style = getComputedStyle(cell);
        return cell.getBoundingClientRect().height <= parseFloat(style.lineHeight) +
          parseFloat(style.paddingTop) + parseFloat(style.paddingBottom) + 2;
      }),
      disclosure: summary.getBoundingClientRect().height >= 44 && summaryStyle.fontWeight === "600" &&
        summaryStyle.columnGap === "8px" && summaryStyle.listStyleType === "none" &&
        parseFloat(chevron.borderTopWidth) > 0 && chevron.backgroundColor === "rgba(0, 0, 0, 0)",
      realDetails: summary.parentElement.tagName === "DETAILS" && !summary.parentElement.open,
      noPageOverflow: document.documentElement.scrollWidth <= window.innerWidth,
      headingFamilies: ["h1", "h2"].every((selector) =>
        getComputedStyle(document.querySelector(selector)).fontFamily.startsWith("ui-serif")) &&
        getComputedStyle(document.querySelector("h3")).fontFamily.includes("-apple-system"),
    };
  });
  for (const [name, passed] of Object.entries(initial)) {
    if (!passed) throw new Error(`Reading check failed: ${name}`);
  }
  const scrolledLocally = await page.locator(".table-scroll").nth(1).evaluate((table) => {
    const pageOffset = window.scrollX;
    table.scrollLeft = table.scrollWidth;
    const scrolled = table.scrollLeft > 100 && window.scrollX === pageOffset;
    table.scrollLeft = 0;
    return scrolled;
  });
  if (!scrolledLocally) throw new Error("Wide table does not scroll independently of the page");
  const summary = page.locator("summary");
  await summary.focus();
  await page.keyboard.press("Enter");
  if (!await page.locator("details").evaluate((node) => node.open)) throw new Error("Keyboard did not open the real disclosure");
  await page.keyboard.press("Space");
  if (await page.locator("details").evaluate((node) => node.open)) throw new Error("Keyboard did not close the real disclosure");

  for (const dark of [false, true]) {
    for (const increasedContrast of [false, true]) {
      for (const bodySize of [17, 36]) {
        const payload = {
          colorScheme: dark ? "dark" : "light", increasedContrast, boldText: false,
          variables: {
            "--gp-page": dark ? "#000000" : "#ffffff",
            "--gp-surface": dark ? "#1c1c1e" : "#f2f2f7",
            "--gp-surface-raised": dark ? "#2c2c2e" : "#ffffff",
            "--gp-text": increasedContrast ? (dark ? "#f8fafc" : "#0f172a") : (dark ? "#e2e8f0" : "#1e293b"),
            "--gp-syntax-code": increasedContrast ? (dark ? "#f1f5f9" : "#334155") : (dark ? "#cbd5e1" : "#475569"),
            "--gp-text-secondary": increasedContrast
              ? (dark ? "#c2c2c6" : "#444447") : (dark ? "rgba(235,235,245,0.6)" : "rgba(60,60,67,0.6)"),
            "--gp-link": dark ? "#64b4ff" : "#005dc2",
            "--gp-separator": dark ? "#38383a" : "#c6c6c8",
            "--gp-boundary": dark ? "#545458" : "#8e8e93",
            "--gp-error": "#ff3b30", "--gp-success": "#34c759",
            "--gp-accent-text": increasedContrast ? (dark ? "#bae6fd" : "#075985") : (dark ? "#7dd3fc" : "#0369a1"),
            "--gp-accent-fill": increasedContrast ? (dark ? "#7dd3fc" : "#0ea5e9") : (dark ? "#38bdf8" : "#0ea5e9"),
            "--gp-on-accent": "#0f172a",
            "--gp-selected-surface": increasedContrast ? (dark ? "#134b63" : "#d4eefc") : (dark ? "#0b3548" : "#e7f6fd"),
            ...Object.fromEntries(["body-size", "body-line-height", "title1-size", "title1-line-height",
              "title2-size", "title2-line-height", "title3-size", "title3-line-height",
              "headline-size", "headline-line-height", "footnote-size", "footnote-line-height", "code-size"]
              .map((name) => [`--gp-${name}`, `${bodySize}px`])),
          },
        };
        await page.evaluate((payload) => window.gistpadPreview.setAppearance(payload), payload);
        await page.waitForFunction(({ dark, increasedContrast }) => {
          const node = document.querySelector(".diagram-scroll .node rect");
          if (!node) return false;
          const expectedStroke = increasedContrast ? (dark ? "rgb(194, 194, 198)" : "rgb(68, 68, 71)")
            : (dark ? "rgb(152, 152, 159)" : "rgb(133, 133, 139)");
          return getComputedStyle(node).fill === (dark ? "rgb(28, 28, 30)" : "rgb(242, 242, 247)") &&
            getComputedStyle(node).stroke === expectedStroke;
        }, { dark, increasedContrast });
        const checks = await page.evaluate(() => {
          const parse = (value) => value.match(/[\d.]+/g).slice(0, 3).map(Number);
          const luminance = (rgb) => rgb.map((value) => {
            value /= 255;
            return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
          }).reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);
          const ratio = (left, right) => {
            const first = luminance(parse(left));
            const second = luminance(parse(right));
            return (Math.max(first, second) + 0.05) / (Math.min(first, second) + 0.05);
          };
          const node = getComputedStyle(document.querySelector(".diagram-scroll .node rect"));
          const arrow = getComputedStyle(document.querySelector(".diagram-scroll .arrowMarkerPath"));
          const edge = getComputedStyle(document.querySelector(".diagram-scroll .flowchart-link"));
          const page = getComputedStyle(document.documentElement);
          const authored = getComputedStyle(document.querySelectorAll(".diagram-scroll")[1].querySelector(".attention rect"));
          const current = getComputedStyle(document.querySelector(".calculation-current"));
          const previous = getComputedStyle(document.querySelector(".calculation-previous"));
          const task = document.querySelector('input[type="checkbox"]:checked');
          const taskStyle = getComputedStyle(task);
          const mark = getComputedStyle(task, "::after");
          const resolveColor = (value) => {
            const probe = document.createElement("span");
            probe.style.color = value;
            document.body.append(probe);
            const resolved = getComputedStyle(probe).color;
            probe.remove();
            return resolved;
          };
          return {
            neutralContrast: ratio(node.stroke, node.fill) >= 3 && ratio(node.stroke, page.backgroundColor) >= 3,
            arrows: ratio(arrow.fill, page.backgroundColor) >= 3 && ratio(edge.stroke, page.backgroundColor) >= 3,
            authored: authored.fill === "rgb(255, 240, 204)" && authored.stroke === "rgb(118, 88, 0)",
            resultColor: current.color === page.color,
            resultSurfaces: current.backgroundColor === resolveColor(page.getPropertyValue("--gp-selected-surface")) &&
              previous.backgroundColor === resolveColor(page.getPropertyValue("--gp-surface")),
            inkContrast: ratio(page.color, page.backgroundColor) >= 4.5 &&
              ratio(current.color, current.backgroundColor) >= 4.5,
            taskContrast: ratio(mark.borderTopColor, taskStyle.backgroundColor) >= 3 &&
              ratio(taskStyle.borderTopColor, page.backgroundColor) >= 3,
            bodyTables: getComputedStyle(document.querySelector("td")).fontSize === page.fontSize,
            bodyDiagrams: parseFloat(document.querySelector(".diagram-scroll svg").style.width) >
              document.querySelector(".diagram-scroll svg").viewBox.baseVal.width,
            noPageOverflow: document.documentElement.scrollWidth <= window.innerWidth,
          };
        });
        for (const [name, passed] of Object.entries(checks)) {
          if (!passed) throw new Error(`Reading theme check failed: ${dark}/${increasedContrast}/${bodySize}/${name}`);
        }
      }
    }
  }
  await page.getByRole("heading", { name: "A considered page", exact: true }).scrollIntoViewIfNeeded();
  return { fixture: "reading-polish", themes: 4, textSizes: 2, externalRequests: "blocked" };
}
