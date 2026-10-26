# Brand marks

`BrandMark(id:)` (App/IconViews.swift) resolves a mark in this order:

1. The installed app's own icon from `NSWorkspace`.
2. A bundled official mark from `App/Assets.xcassets` (table below).
3. A monogram tile (first letter, neutral chip).

Rules that apply to every bundled mark: shown only to say "Perry connects to this app", never recoloured, never combined with other graphics, never used as Perry's own logo, always beside the app's plain name. Files are unmodified from the source download. Size is changed only by scaling.

## Bundled

| Asset | Source file | Source URL | Guideline URL | Rule followed |
|---|---|---|---|---|
| `brand-linear` | `linear-icon.svg` (512 x 512) | https://static.linear.app/design-assets/Linear-Brand-Assets.zip?v=3 (linked from the brand page) | https://linear.app/brand | "Provide plenty of space around Linear assets." "Do not alter these files in any way." Shown at its native colours inside the square icon, with a continuous rounded corner (radius 22.5 percent of the size), which the page allows ("it is acceptable to use this stylized icon with an appropriate corner radius"). Never combined with other graphics. |
| `brand-github` | `GitHub_Invertocat_White.svg` | https://brand.github.com/GitHub_Logos.zip (linked as "Download the logo files") | https://brand.github.com/foundations/logo | "The Invertocat and our wordmark should only appear in white, black, or in few cases grey or green." The white Invertocat sits unaltered on a black tile with 20 percent padding on each side as clear space. The page allows "a permitted GitHub logo to inform others that your project integrates with GitHub". |
| `brand-google-drive` | `logo_drive_2026_color_2x_web_64dp.png` (128 x 128) | https://www.gstatic.com/images/branding/productlogos/drive_2026/v2/web-64dp/logo_drive_2026_color_2x_web_64dp.png (the "Google Drive product logo" link on the guideline page) | https://developers.google.com/workspace/drive/api/guides/branding | Resizing only: "don't make any other changes to the logo." Used "to indicate that a file is stored in Google Drive" style references, beside the full name "Google Drive". |
| `brand-google-calendar` | `logo_calendar_2026_color_2x_web_64dp.png` (128 x 128) | https://www.gstatic.com/images/branding/productlogos/calendar_2026/v1/web-64dp/logo_calendar_2026_color_2x_web_64dp.png | https://partnermarketinghub.withgoogle.com/brands/google/use-cases/product-co-branding/#referring-to-google-apis | Same rules as Drive (no changes, resize only). Google's page: "Use product icons only when necessary." and "Make sure it doesn't seem like this is coming from Google." The file comes from the same Google product-logo CDN as the Drive logo. No Calendar-specific branding page exists (the Calendar guide URLs return 404), so the Drive page and the partner page are the rule set. |
| `brand-google-gmail` | `logo_gmail_2020q4_color_2x_web_64dp.png` (128 x 128) | https://www.gstatic.com/images/branding/productlogos/gmail_2020q4/v11/web-64dp/logo_gmail_2020q4_color_2x_web_64dp.png | https://partnermarketinghub.withgoogle.com/brands/google/use-cases/product-co-branding/#referring-to-google-apis | Same as Calendar. No Gmail-specific branding page was found. |
| `brand-notion` | `Notion-logo.svg` | https://upload.wikimedia.org/wikipedia/commons/e/e9/Notion-logo.svg | https://www.notion.com/brand (401 without sign-in) | Owner approved on 2026-10-26. Shown unaltered, only beside the name "Notion", only to say Perry connects to it. |
| `brand-slack` | `Slack_icon_2019.svg` | https://upload.wikimedia.org/wikipedia/commons/d/d5/Slack_icon_2019.svg | https://slack.com/media-kit | Owner approved on 2026-10-26. The mark sits unaltered on a white tile with 20 percent clear space, beside the name "Slack". |
| `brand-microsoft` | `Microsoft_365_2022.svg` | https://upload.wikimedia.org/wikipedia/commons/0/0e/Microsoft_365_%282022%29.svg | Microsoft 365 trademark guidelines (PDF linked above) | Owner approved on 2026-10-26. Shown unaltered beside the name "Microsoft 365", never decoratively. |

## Owner decision

On 2026-10-26 the owner approved shipping the Notion, Slack and Microsoft 365 marks as "works with" references, after reading why they were first skipped. The files come from Wikimedia Commons copies of the official marks because the brand portals need sign-in. Before a public release, replace each with the file from the official portal and confirm the terms.

## To revisit

Ask each owner for written permission or find a signed-in copy of the Notion brand page and the Slack brand centre. Add the file to `App/Assets.xcassets/brand-<id>.imageset`, set `asset:` in `BrandCatalog`, and add a row to the first table.
