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
    const summary = document.querySelector("details:not(.markdown-toc) summary");
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
      headingFamilies: ["h1", "h2", "h3"].every((selector) =>
        getComputedStyle(document.querySelector(selector)).fontFamily.includes("-apple-system")),
      compactContents: !document.querySelector("details.markdown-toc").open &&
        document.querySelector(".markdown-toc").getBoundingClientRect().height >= 44 &&
        document.querySelector(".markdown-toc").getBoundingClientRect().height <= 54 &&
        getComputedStyle(document.querySelector(".markdown-toc > summary")).fontFamily.includes("-apple-system"),
      authoredOpenState: document.querySelectorAll("details:not(.markdown-toc)")[1].open,
      pageRhythm: getComputedStyle(document.querySelector("main")).padding === "24px 20px 40px" &&
        Math.abs(parseFloat(getComputedStyle(document.querySelector("h1")).marginBottom) - 17 * 16 / 9) < .1 &&
        Math.abs(parseFloat(getComputedStyle(document.querySelector("h2")).marginTop) - 51) < .1 &&
        Math.abs(parseFloat(getComputedStyle(document.querySelector("h2")).marginBottom) - 25.5) < .1 &&
        Math.abs(parseFloat(getComputedStyle(document.querySelector("h3")).marginTop) - 34) < .1,
      contentsHeadingGap: Math.abs(document.querySelector(".markdown-toc").nextElementSibling.getBoundingClientRect().top -
        document.querySelector(".markdown-toc").getBoundingClientRect().bottom - 51) < .1,
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
  const summary = page.locator("details:not(.markdown-toc) summary").first();
  await summary.focus();
  await page.keyboard.press("Enter");
  if (!await page.locator("details:not(.markdown-toc)").first().evaluate((node) => node.open)) throw new Error("Keyboard did not open the real disclosure");
  await page.keyboard.press("Space");
  if (await page.locator("details:not(.markdown-toc)").first().evaluate((node) => node.open)) throw new Error("Keyboard did not close the real disclosure");
  const contents = page.locator("details.markdown-toc");
  await contents.locator("summary").focus();
  await page.keyboard.press("Enter");
  if (!await contents.evaluate((node) => node.open)) throw new Error("Keyboard did not open Contents");
  await page.evaluate((markdown) =>
    window.gistpadPreview.render({ version: 1, documentID: "reading-polish", generation: "2", markdown }), markdown);
  await page.waitForFunction(() => document.querySelector("details.markdown-toc").open);
  await contents.locator("summary").click();

  for (const dark of [false, true]) {
    for (const increasedContrast of [false, true]) {
      for (const { bodySize, headingSizes } of [
        { bodySize: 17, headingSizes: [34, 25.5, 21.25] },
        { bodySize: 40, headingSizes: [52, 47.5, 44.25] },
        { bodySize: 53, headingSizes: [60, 59.5, 56.25] },
      ]) {
        const payload = {
          colorScheme: dark ? "dark" : "light", increasedContrast, boldText: false,
          variables: {
            "--gp-page": dark ? "#000000" : "#ffffff",
            "--gp-surface": dark ? "#1c1c1e" : "#f2f2f7",
            "--gp-surface-raised": dark ? "#2c2c2e" : "#ffffff",
            "--gp-text": dark ? "#ffffff" : "#000000",
            "--gp-syntax-code": increasedContrast ? (dark ? "#f1f5f9" : "#334155") : (dark ? "#cbd5e1" : "#475569"),
            "--gp-text-secondary": increasedContrast
              ? (dark ? "#c2c2c6" : "#444447") : (dark ? "rgba(235,235,245,0.6)" : "rgba(60,60,67,0.6)"),
            "--gp-list-marker": increasedContrast
              ? (dark ? "#c2c2c6" : "#555559") : (dark ? "#8e8e93" : "#757579"),
            "--gp-list-bullet": increasedContrast
              ? (dark ? "#c2c2c6" : "#555559") : (dark ? "#525252" : "#d4d4d4"),
            "--gp-list-number": increasedContrast
              ? (dark ? "#c2c2c6" : "#555559") : (dark ? "#a1a1a1" : "#737373"),
            "--gp-link": dark ? "#64b4ff" : "#005dc2",
            "--gp-separator": dark ? "#38383a" : "#c6c6c8",
            "--gp-boundary": dark ? "#545458" : "#8e8e93",
            "--gp-error": "#ff3b30", "--gp-success": "#34c759",
            "--gp-accent-text": bodySize !== 17 ? (dark ? "#facc15" : "#665200")
              : increasedContrast ? (dark ? "#bae6fd" : "#075985") : (dark ? "#7dd3fc" : "#0369a1"),
            "--gp-accent-fill": bodySize !== 17 ? "#facc15"
              : increasedContrast ? (dark ? "#7dd3fc" : "#0ea5e9") : (dark ? "#38bdf8" : "#0ea5e9"),
            "--gp-on-accent": "#0f172a",
            "--gp-selected-surface": increasedContrast ? (dark ? "#134b63" : "#d4eefc") : (dark ? "#0b3548" : "#e7f6fd"),
            ...Object.fromEntries(["body-size", "body-line-height", "title1-size", "title1-line-height",
              "title2-size", "title2-line-height", "title3-size", "title3-line-height",
              "headline-size", "headline-line-height", "footnote-size", "footnote-line-height", "code-size"]
              .map((name) => [`--gp-${name}`, `${bodySize}px`])),
            ...Object.fromEntries(headingSizes.map((size, index) => [`--gp-title${index + 1}-size`, `${size}px`])),
          },
        };
        await page.evaluate((payload) => window.gistpadPreview.setAppearance(payload), payload);
        await page.waitForFunction(({ dark }) => {
          const diagram = document.querySelector(".diagram-scroll");
          const node = document.querySelector(".diagram-scroll .node rect");
          if (!node) return false;
          const theme = JSON.parse(diagram.dataset.nativeTheme);
          const expectedStroke = `rgb(${theme.stroke.join(", ")})`;
          return getComputedStyle(node).fill === (dark ? "rgb(28, 28, 30)" : "rgb(242, 242, 247)") &&
            getComputedStyle(node).stroke === expectedStroke &&
            getComputedStyle(diagram.querySelector(".flowchart-link")).stroke === `rgb(${theme.edge.join(", ")})`;
        }, { dark });
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
            roundedRectangles: node.rx === "10px" && node.ry === "10px" && node.strokeWidth === "1px",
            shapeMeaning: document.querySelectorAll(".diagram-scroll")[1].querySelector(".node polygon") !== null,
            personalAccent: edge.stroke === resolveColor(page.getPropertyValue("--gp-accent-text")) &&
              getComputedStyle(document.querySelector(".text-blue-500")).color === resolveColor(page.getPropertyValue("--gp-accent-text")),
            labelInk: getComputedStyle(document.querySelector(".diagram-scroll .nodeLabel")).color === page.color &&
              getComputedStyle(document.querySelector("h1")).color === page.color &&
              getComputedStyle(document.querySelector("h2")).color === page.color,
            authored: authored.fill === "rgb(255, 240, 204)" && authored.stroke === "rgb(118, 88, 0)",
            resultColor: current.color === page.color,
            resultSurfaces: current.backgroundColor === resolveColor(page.getPropertyValue("--gp-selected-surface")) &&
              previous.backgroundColor === resolveColor(page.getPropertyValue("--gp-surface")),
            inkContrast: ratio(page.color, page.backgroundColor) >= 4.5 &&
              ratio(current.color, current.backgroundColor) >= 4.5,
            taskContrast: ratio(mark.borderTopColor, taskStyle.backgroundColor) >= 3 &&
              ratio(taskStyle.borderTopColor, page.backgroundColor) >= 3,
            neutralTasks: [...document.querySelectorAll(".task-toggle input")].every((input) => {
              const box = getComputedStyle(input);
              return box.borderTopColor === resolveColor(page.getPropertyValue("--gp-list-marker")) &&
                (!input.checked || box.backgroundColor === resolveColor(page.getPropertyValue("--gp-list-marker"))) &&
                input.closest(".task-toggle").getBoundingClientRect().height >= 44 &&
                getComputedStyle(input.closest("li")).color === page.color;
            }),
            bodyTables: getComputedStyle(document.querySelector("td")).fontSize === page.fontSize,
            headingScale: ["h1", "h2", "h3"].every((selector, index) =>
              Math.abs(parseFloat(getComputedStyle(document.querySelector(selector)).fontSize) -
                parseFloat(page.getPropertyValue(`--gp-title${index + 1}-size`))) < .1),
            headingRules: ["h1", "h2"].every((selector) => {
              const heading = getComputedStyle(document.querySelector(selector));
              return heading.borderBottomWidth === "1px" &&
                heading.borderBottomColor === resolveColor(page.getPropertyValue("--border")) &&
                Math.abs(parseFloat(heading.paddingBottom) - parseFloat(page.fontSize)) < .1;
            }),
            sansHeadings: [...document.querySelectorAll("h1,h2,h3,h4,h5,h6")].every((heading) =>
              getComputedStyle(heading).fontFamily.includes("-apple-system")),
            proseRhythm: Math.abs(parseFloat(getComputedStyle(document.querySelector("article")).lineHeight) -
              1.75 * parseFloat(page.fontSize)) < .1 &&
              Math.abs(parseFloat(getComputedStyle(document.querySelector("article > p")).marginBottom) -
                1.25 * parseFloat(page.fontSize)) < .1 &&
              Math.abs(parseFloat(getComputedStyle(document.querySelector("li.task-list-item")).marginBottom) -
                .5 * parseFloat(page.fontSize)) < .1,
            authoredLists: document.querySelector("article > ol").start === 3 &&
              document.querySelectorAll("article > ol > li, article > ul:not(.contains-task-list) li").length === 4,
            listMarkers: [...document.querySelectorAll("article > ol > li, article > ul:not(.contains-task-list) li")].every((item) => {
              const marker = getComputedStyle(item, "::marker");
              const text = getComputedStyle(item);
              const bullet = item.parentElement.tagName === "UL";
              const increased = document.documentElement.dataset.contrast === "increased";
              return marker.color === resolveColor(page.getPropertyValue(bullet ? "--gp-list-bullet" : "--gp-list-number")) &&
                (bullet && !increased || ratio(marker.color, page.backgroundColor) >= (increased ? 7 : 4.5)) &&
                text.color === page.color && marker.fontWeight === text.fontWeight;
            }),
            markerExclusions: [...document.querySelectorAll(".markdown-toc li, li.task-list-item")].every((item) =>
              getComputedStyle(item, "::marker").color === page.color),
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
  const mangaResponse = await page.request.get(`${base}/Fixtures/manga-reading.md`);
  if (!mangaResponse.ok()) throw new Error("Manga reading fixture is missing");
  await page.evaluate((markdown) =>
    window.gistpadPreview.render({ version: 1, documentID: "manga-reading", generation: "1", markdown }),
  await mangaResponse.text());
  await page.getByRole("heading", { name: "👓 Currently reading (volume)", exact: true }).waitFor();
  for (const width of [320, 382, 834]) {
    await page.setViewportSize({ width, height: 874 });
    const checks = await page.evaluate(() => {
      const bodySize = parseFloat(getComputedStyle(document.documentElement).fontSize);
      const heading = document.querySelector("h1");
      const list = document.querySelector("ol");
      const item = list.querySelector("li");
      return {
        exactStart: list.start === 3 && item.textContent === "Billy Bat (14)",
        coloredNumbers: getComputedStyle(item, "::marker").color !== getComputedStyle(item).color,
        listRhythm: Math.abs(parseFloat(getComputedStyle(item).marginBottom) - .5 * bodySize) < .1 &&
          Math.abs(parseFloat(getComputedStyle(list).paddingInlineStart) - 1.625 * bodySize) < .1,
        singlePageInset: Math.abs(heading.getBoundingClientRect().top +
          window.scrollY - 24) < .1,
        noPageOverflow: document.documentElement.scrollWidth <= window.innerWidth,
      };
    });
    for (const [name, passed] of Object.entries(checks)) {
      if (!passed) throw new Error(`Manga check failed: ${width}/${name}`);
    }
  }
  const wrappingResponse = await page.request.get(`${base}/Fixtures/heading-wrapping.md`);
  if (!wrappingResponse.ok()) throw new Error("Heading wrapping fixture is missing");
  await page.evaluate((markdown) =>
    window.gistpadPreview.render({ version: 1, documentID: "heading-wrapping", generation: "1", markdown }),
  await wrappingResponse.text());
  await page.getByRole("heading", { level: 3, name: "The shape of a notebook", exact: true }).waitFor();
  for (const width of [382, 834]) {
    await page.setViewportSize({ width, height: 874 });
    const checks = await page.evaluate(() => {
      const headings = ["h1", "h2", "h3"].map((selector) => document.querySelector(selector));
      const oversized = document.querySelectorAll("h1")[1];
      const oversizedRange = document.createRange();
      oversizedRange.selectNodeContents(oversized);
      return {
        wholeWords: headings.every((heading) => {
          const text = document.createTreeWalker(heading, NodeFilter.SHOW_TEXT).nextNode();
          if (!text || text.textContent !== heading.textContent) return false;
          return [...text.textContent.matchAll(/\S+/g)].every((word) => {
            const range = document.createRange();
            range.setStart(text, word.index);
            range.setEnd(text, word.index + word[0].length);
            return range.getClientRects().length === 1;
          });
        }),
        emergencyWrapping: oversizedRange.getClientRects().length > 1,
        noPageOverflow: document.documentElement.scrollWidth <= window.innerWidth,
      };
    });
    for (const [name, passed] of Object.entries(checks)) {
      if (!passed) throw new Error(`Heading wrapping check failed: ${width}/${name}`);
    }
  }
  return { fixtures: ["reading-polish", "manga-reading", "heading-wrapping"], themes: 4, textSizes: 3, externalRequests: "blocked" };
}
