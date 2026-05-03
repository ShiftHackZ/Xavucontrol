const releaseApiUrl = "https://api.github.com/repos/ShiftHackZ/Xavucontrol/releases/latest";
const releasePageUrl = "https://github.com/ShiftHackZ/Xavucontrol/releases/latest";

function findDmgAsset(release) {
  if (!release || !Array.isArray(release.assets)) {
    return null;
  }

  return release.assets.find((asset) => {
    const name = String(asset.name || "").toLowerCase();
    return name.endsWith(".dmg") && typeof asset.browser_download_url === "string";
  });
}

async function resolveLatestDmg() {
  const response = await fetch(releaseApiUrl, {
    headers: {
      Accept: "application/vnd.github+json",
    },
  });

  if (!response.ok) {
    throw new Error(`GitHub release lookup failed: ${response.status}`);
  }

  return findDmgAsset(await response.json());
}

async function wireDownloadButtons() {
  const downloadLinks = document.querySelectorAll("[data-download-dmg]");
  if (!downloadLinks.length) {
    return;
  }

  try {
    const dmgAsset = await resolveLatestDmg();
    if (!dmgAsset) {
      return;
    }

    downloadLinks.forEach((link) => {
      link.href = dmgAsset.browser_download_url;
      link.setAttribute("download", dmgAsset.name);
      link.setAttribute("title", `Download ${dmgAsset.name}`);
    });
  } catch (error) {
    console.warn(error);
    downloadLinks.forEach((link) => {
      link.href = releasePageUrl;
      link.removeAttribute("download");
    });
  }
}

wireDownloadButtons();
