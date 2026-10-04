#!/usr/bin/env python3
"""从中文版法律网页生成英文版。

**为什么要生成而不是手写**：两版必须视觉一致（同一套 CSS、同一套 nav 与
footer 结构）。手抄一遍样式，过几个月改配色就会只改中文版，两页慢慢长得不一样 ——
审核员对照 App 内截图与网页截图时一眼能看出来。

**为什么不用模板引擎**：就三个文件，引入 jinja2 换三个页面的日常维护成本，
不划算。直接从现有 HTML 里正则抽 <style> 块复用。

用法：
    python3 tool/gen_legal_en.py           # 生成三个 .en.html
    python3 tool/gen_legal_en.py --check   # 只校验已生成文件与正文一致
"""
from __future__ import annotations

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.dirname(HERE)
LEGAL = os.path.join(SERVER, "legal")


def extract_style(html: str) -> str:
    m = re.search(r"<style>(.*?)</style>", html, re.DOTALL)
    if not m:
        raise SystemExit("中文版页面里找不到 <style> 块")
    return m.group(1).strip()


def extract_body(html: str) -> str:
    m = re.search(r"<main>(.*?)</main>", html, re.DOTALL)
    if not m:
        raise SystemExit("中文版页面里找不到 <main> 块")
    return m.group(1).strip()


PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{description}">
<style>
{style}
</style>
</head>
<body>
<main>
{body}
</body>
</html>
"""

# ---- 英文版正文 --------------------------------------------------------
# 逐条对照 assets/legal/*.en.md（App 内版本）。**两处必须一致** ——
# 商店审核同时看 App 内与网页版，不一致会被要求补材料。

PRIVACY_EN = """
<nav>
<a href="/legal/privacy?lang=en">Privacy Policy</a>
<a href="/legal/terms?lang=en">Terms of Use</a>
<a href="/legal/account-deletion?lang=en">Delete account</a>
</nav>

<h1>My Pet · Privacy Policy</h1>
<p class="meta"><strong>Effective date:</strong> 30 September 2026 &nbsp;·&nbsp;
<strong>Last updated:</strong> 30 September 2026</p>

<p>This policy explains what information &ldquo;My Pet&rdquo; (the &ldquo;App&rdquo;)
collects, how we use it, where it is stored, and how you can manage it.
The operator is <strong>Linyi Weiyuan Tools</strong>.</p>

<blockquote>
<p>This policy is written to match the App&rsquo;s actual, current behaviour. If
something is not in the App &mdash; advertising SDKs, analytics tracking, server-side
push, AI analysis &mdash; it is not listed here. Describing collection that does not
exist is worse than omitting it: if a store audit finds the mismatch, the policy
loses your trust for good.</p>
</blockquote>

<hr>

<h2>1. The short version</h2>

<p><strong>Your pet&rsquo;s data stays on your phone by default.</strong> It is only
sent to the server for your region after you deliberately sign in. Photos are never
uploaded.</p>

<hr>

<h2>2. What we collect</h2>

<h3>2.1 Information you enter</h3>

<table>
<thead><tr><th>Content</th><th>Purpose</th><th>Required?</th></tr></thead>
<tbody>
<tr><td>Pet profile (name, breed, sex, birthday, weight, colour, neuter status,
microchip number, personality tags)</td><td>Build the profile; generate vaccine and
deworming reminders</td><td>Yes &mdash; the App cannot work without it</td></tr>
<tr><td>Entries (weight, vaccine, deworming, medication, vet visits, feeding,
bathroom, notes)</td><td>Timeline and health overview</td><td>Yes</td></tr>
<tr><td>Pet photos</td><td>Profile avatar, entry attachments, lost-pet poster</td>
<td>Optional</td></tr>
<tr><td>Walk traces (latitude/longitude)</td><td>Record walk distance and route</td>
<td>Optional (requires location permission)</td></tr>
</tbody>
</table>

<h3>2.2 Account and contact details (only after you sign in)</h3>

<table>
<thead><tr><th>Content</th><th>Purpose</th></tr></thead>
<tbody>
<tr><td>Phone number or email</td><td>Sign in, account recovery, co-care
invitations</td></tr>
<tr><td>Display name</td><td>Lets others recognise you in co-care</td></tr>
<tr><td>WeChat / other contact details</td><td><strong>Used only on the lost-pet
poster</strong> &mdash; printed on the card so whoever finds your pet can reach
you</td></tr>
</tbody>
</table>

<h3>2.3 What we do <strong>not</strong> collect</h3>

<ul>
<li>No contacts, SMS messages, or call logs</li>
<li>No device identifiers (IMEI / OAID / advertising ID)</li>
<li>No behavioural tracking, no user profiling, no advertising SDKs</li>
<li>No third-party analytics services</li>
<li>We do not read your other photos &mdash; we only take the single image you select
in the system photo picker</li>
</ul>

<hr>

<h2>3. Where your data is stored</h2>

<p>The App is <strong>local-first</strong>, and the two regions run on separate
infrastructure:</p>

<table>
<thead><tr><th>Data</th><th>Location</th></tr></thead>
<tbody>
<tr><td>Pet profile, entries, reminders, traces</td><td><strong>On-device
database</strong> (the App&rsquo;s private directory, unreadable by other
apps)</td></tr>
<tr><td>Photos, avatar</td><td><strong>On-device files</strong> (the App&rsquo;s
private directory). <strong>Never uploaded.</strong></td></tr>
<tr><td>Account, display name, contact details</td><td>Mainland China users &rarr;
servers located in Mainland China; overseas users &rarr; overseas servers</td></tr>
</tbody>
</table>

<p><strong>The two regions are fully isolated, with no cross-border transfer.</strong>
Personal data of users in Mainland China never leaves the country, and personal data of
overseas users is never sent back into China. This is a structural decision made to
avoid cross-border compliance review entirely &mdash; not an assessment written after
the fact.</p>

<hr>

<h2>4. Who we share your data with</h2>

<p><strong>Nobody.</strong> Specifically:</p>

<ul>
<li>We do not sell, share, or transfer your data to advertisers or data brokers</li>
<li>We do not integrate third-party SDKs for payments, social features, or
analytics</li>
<li>We disclose data only where <strong>the law explicitly requires it</strong> (for
example, a court order), and we will tell you within whatever bounds the law
allows</li>
</ul>

<hr>

<h2>5. Third-party services</h2>

<table>
<thead><tr><th>Service</th><th>When it is used</th><th>What is sent</th></tr></thead>
<tbody>
<tr><td>SMS / email provider</td><td>When you request a sign-in code</td><td>Your
phone number or email (used only to deliver the code)</td></tr>
<tr><td>In-app update check</td><td>When you open the App</td><td>Requests a version
manifest only; carries no personal information</td></tr>
<tr><td>Map tiles (overseas version only)</td><td>When you view a walk trace</td>
<td>Map tile requests include the <strong>coordinates of the area you are
viewing</strong> &mdash; this is inherent to how map services work</td></tr>
</tbody>
</table>

<blockquote>
<p>The Mainland China version <strong>does not render map tiles</strong> (map display
inside the mainland requires a survey licence), so no such request is made.</p>
</blockquote>

<hr>

<h2>6. Permissions</h2>

<p>Every permission this App requests maps to a feature you can see. Declining one
does not affect the others:</p>

<table>
<thead><tr><th>Permission</th><th>Purpose</th><th>If you decline</th></tr></thead>
<tbody>
<tr><td>Notifications</td><td>Due-date reminders for vaccines, deworming,
check-ups</td><td>No reminders; everything else works</td></tr>
<tr><td>Camera / Photo library</td><td>Profile avatar, photos on entries</td>
<td>Cannot add images</td></tr>
<tr><td>Location (while using only)</td><td>Record walk traces and distance</td>
<td>No traces; you can still log walks manually</td></tr>
<tr><td>Network</td><td>Sign in, multi-device sync, update checks</td>
<td>Single-device use only</td></tr>
<tr><td>Launch at startup</td><td>Rebuild scheduled reminders after a
restart</td><td>Reminders are lost after a restart</td></tr>
</tbody>
</table>

<p>We do <strong>not</strong> request contacts, SMS, call logs, or continuous
background location.</p>

<hr>

<h2>7. Retention and deletion</h2>

<ul>
<li><strong>On-device data:</strong> deleted when you uninstall the App. You can
also delete entries individually inside the App (deletion is soft: the item is marked
deleted locally and hidden from view).</li>
<li><strong>Account:</strong> sign out under &ldquo;Me &rarr; Data sync&rdquo;. After
signing out, local data is kept but no longer uploaded.</li>
<li><strong>Server-side data:</strong> to close your account and delete server-side
data, email <code>zhuruipeng@weiyuantool.com</code> with the phone number or email
you signed in with. We complete the deletion and reply within <strong>15 working
days</strong>. Deletion cannot be undone.</li>
</ul>

<hr>

<h2>8. Security</h2>

<ul>
<li>The sign-in token lives only on your device; the server stores a <strong>hash</strong>
of it (the server cannot retrieve the plaintext token either)</li>
<li>Signing out immediately invalidates that token on the server</li>
<li>All traffic is over HTTPS</li>
<li>Photos never leave the phone, so there is no cloud exposure to worry
about</li>
</ul>

<blockquote>
<p>One point worth being explicit about: the sign-in token is currently stored in the
App&rsquo;s private directory. On unjailbroken / unrooted devices other apps cannot
read that directory, but it is not a system-level keychain. This is on our improvement
list.</p>
</blockquote>

<hr>

<h2>9. Children</h2>

<p>The App is intended for pet owners, not for minors, and we do not knowingly
collect personal information from children. If a guardian finds that a minor has used
the App without consent, contact us and we will delete the relevant data.</p>

<hr>

<h2>10. Your rights</h2>

<p>Whether you are in Mainland China or overseas, you can:</p>

<ul>
<li>See what data we hold about you (visible directly in the App, or ask us for an
export)</li>
<li>Correct inaccurate data (editable directly in the App)</li>
<li>Delete data (delete in the App, or ask us to close your account)</li>
<li>Refuse or withdraw consent (turn the permission off in system settings)</li>
</ul>

<p>Overseas users have additional rights under GDPR / CCPA (portability, the right to
object to processing, non-discrimination, and so on). To exercise any of them, email the
address below.</p>

<hr>

<h2>11. Changes to this policy</h2>

<p>When functionality changes &mdash; for example, if we later add cloud photo sync or
paid features &mdash; we will update this policy and notify you in the App. Continuing
to use the App means you accept the updated version.</p>

<hr>

<h2>12. Contact us</h2>

<ul>
<li><strong>Operator:</strong> Linyi Weiyuan Tools</li>
<li><strong>Email:</strong> <code>zhuruipeng@weiyuantool.com</code></li>
<li><strong>Website:</strong> <a href="https://weiyuantool.com">https://weiyuantool.com</a></li>
</ul>

<p>We respond to personal-information questions within <strong>15 working days</strong>.</p>

<footer>This policy applies to both the Mainland China version of &ldquo;My
Pet&rdquo; (com.weiyuantool.pet_app) and the international version
(com.weiyuantool.pet).</footer>
"""

TERMS_EN = """
<nav>
<a href="/legal/privacy?lang=en">Privacy Policy</a>
<a href="/legal/terms?lang=en">Terms of Use</a>
<a href="/legal/account-deletion?lang=en">Delete account</a>
</nav>

<h1>My Pet · Terms of Use</h1>
<p class="meta"><strong>Effective date:</strong> 30 September 2026</p>

<p>Please read these terms before using &ldquo;My Pet&rdquo;. By using the App you
accept them. The operator is <strong>Linyi Weiyuan Tools</strong>
(&ldquo;we&rdquo;, &ldquo;us&rdquo;).</p>

<hr>

<h2>1. What the App does</h2>

<p>The App provides pet health profiles and reminder management:</p>

<ul>
<li>Create a pet profile (breed, birthday, weight, neuter status, and so on)</li>
<li>Record weight, vaccines, deworming, medication, vet visits, feeding, bathroom, and
other entries, with optional photo attachments</li>
<li>Generate <strong>suggested schedules</strong> based on your pet&rsquo;s species,
age, and the general immunisation guidelines for your region</li>
<li>Notify you when a schedule is due (local notifications)</li>
<li>Record walk traces and distances</li>
<li>Sync across multiple devices after you sign in, and invite family members to
record for the same pet</li>
<li>Generate a lost-pet poster (an image) for you to share yourself</li>
</ul>

<hr>

<h2>2. Important: reminders are not veterinary advice</h2>

<blockquote>
<p><strong>This is the clause in these terms that matters most.</strong></p>
</blockquote>

<p>The vaccine, deworming, and check-up schedules in the App are
<strong>suggestions</strong> derived from <strong>published general immunisation
guidelines</strong>. They are not a diagnosis, a prescription, or a treatment plan for
your individual animal. They cannot account for:</p>

<ul>
<li>Your pet&rsquo;s medical history, allergies, or current medications</li>
<li>Recent disease outbreaks in your area</li>
<li>Individual differences (breed, size, health status)</li>
</ul>

<p><strong>Always follow your licensed vet&rsquo;s advice.</strong> If you notice any
abnormal symptoms, see a vet directly rather than relying on this App&rsquo;s
reminders.</p>

<hr>

<h2>3. Your responsibilities</h2>

<ol>
<li><strong>Keep your account secure.</strong> Do not forward your sign-in codes to
anyone else. Only send co-care invitations to people you trust &mdash; an invited
person can see all records for that pet.</li>
<li><strong>Enter information accurately.</strong> Errors in weight or medication
dosage directly reduce the usefulness of your reminders.</li>
<li><strong>You are responsible for lost-pet poster content.</strong> You enter the
contact details, so please check them yourself. When sharing, hide any information you
do not want made public.</li>
<li><strong>Do not use the App for unlawful purposes.</strong> Do not upload illegal
or infringing content.</li>
</ol>

<hr>

<h2>4. Account and data</h2>

<ul>
<li>You can sign out at any time. After signing out, local data is kept but no longer
uploaded.</li>
<li>To close your account and delete server-side data, email
<code>zhuruipeng@weiyuantool.com</code>.</li>
<li>We handle your personal information as described in the
<strong>Privacy Policy</strong>.</li>
</ul>

<hr>

<h2>5. Free now, paid later</h2>

<p>The current version is <strong>completely free, with no in-app purchases and no
ads</strong>.</p>

<p>We may introduce paid features in future (for example, cloud photo sync, or more pet
slots). If we do, we will:</p>

<ul>
<li>Guarantee that existing free features <strong>do not shrink</strong> &mdash; we
will not turn something we already gave you away for free into a paid feature</li>
<li>Show the price and contents clearly before any purchase</li>
<li>Always let you export or keep the data you already have</li>
</ul>

<hr>

<h2>6. Changes to and interruptions of the service</h2>

<ul>
<li>We will do our best to keep the service available, but we do not promise it will
never be interrupted. <strong>Core functions (recording, viewing, and reminders) are
not affected while you are offline</strong> &mdash; that is the point of a local-first
design.</li>
<li>If the service for a region needs to be shut down, we will give <strong>30
days&rsquo; notice</strong> inside the App and make sure you can export your
data.</li>
</ul>

<hr>

<h2>7. Disclaimers</h2>

<ol>
<li>We are not responsible for reminders that are off because <strong>you entered the
wrong information</strong> (for example, putting &ldquo;vaccine&rdquo; in the breed
field, or recording a weight of 234 kg).</li>
<li>We are not responsible for missed reminders caused by <strong>phone system
settings</strong> &mdash; notification permission disabled, power-saving mode on, or
the vendor&rsquo;s background process cleanup. We recommend adding this App to the
&ldquo;unrestricted&rdquo; background list in your system settings.</li>
<li>The lost-pet poster is content <strong>you share yourself</strong>; you are
responsible for how far it spreads and what it leads to.</li>
<li>Other disclaimers to the extent permitted by law.</li>
</ol>

<hr>

<h2>8. Intellectual property</h2>

<ul>
<li>The App&rsquo;s name, icon, and interface design belong to us.</li>
<li><strong>The pet data you enter belongs to you.</strong> We will not use it for
anything, and we will not use it to train models.</li>
<li>You can export this data at any time.</li>
</ul>

<hr>

<h2>9. Changes to these terms</h2>

<p>We will notify you inside the App when these terms are updated. If you disagree with
the changes, you can stop using the App and delete your account. Continuing to use it
means you accept the new version.</p>

<hr>

<h2>10. Governing law and contact</h2>

<ul>
<li><strong>Governing law:</strong> the laws of the State of Delaware, United States of
America, without regard to its conflict-of-law rules. If you are a consumer resident in
a jurisdiction with mandatory consumer protections, those protections still apply to you
and are not waived by this clause.</li>
<li><strong>Operator:</strong> Linyi Weiyuan Tools</li>
<li><strong>Email:</strong> <code>zhuruipeng@weiyuantool.com</code></li>
<li><strong>Website:</strong> <a href="https://weiyuantool.com">https://weiyuantool.com</a></li>
</ul>

<p>If you have questions, email us first &mdash; we reply within <strong>15 working
days</strong>.</p>

<footer>These terms apply to both the Mainland China version of &ldquo;My
Pet&rdquo; (com.weiyuantool.pet_app) and the international version
(com.weiyuantool.pet).</footer>
"""

DELETION_EN = """
<nav>
<a href="/legal/privacy?lang=en">Privacy Policy</a>
<a href="/legal/terms?lang=en">Terms of Use</a>
<a href="/legal/account-deletion?lang=en">Delete account</a>
</nav>

<h1>Delete your account and data</h1>
<p class="meta">Applies to both the Mainland China and international versions of
&ldquo;My Pet&rdquo; &nbsp;·&nbsp; <strong>Updated:</strong> 30 September 2026</p>

<p>This page explains how to close your account, what gets deleted, what
<em>cannot</em> be deleted, and how long it takes.</p>

<h2>1. Two different things</h2>

<p>&ldquo;My Pet&rdquo; is local-first. Your pet&rsquo;s profile, entries, and photos
live on your phone; only after you sign in does part of that sync to our servers.
So <strong>signing out</strong> and <strong>closing your account</strong> are
different operations:</p>

<table>
<thead><tr><th>Operation</th><th>What happens</th><th>How</th></tr></thead>
<tbody>
<tr>
<td>Sign out</td>
<td>All local data is kept, it just stops uploading. Data on the server also stays
&mdash; sign in again and it comes back.</td>
<td>In the App: <strong>Me &rarr; Data sync &rarr; Sign out</strong></td>
</tr>
<tr>
<td>Close account</td>
<td>The account and its synced data are deleted from the server and cannot be
recovered. Local data on your phone is unaffected.</td>
<td>See section 2 below</td>
</tr>
</tbody>
</table>

<h2>2. How to close your account</h2>

<p>For now this is done by email (a self-service deletion flow is not yet in the
App; it is on our improvement list).</p>

<ul>
<li>Email <code>zhuruipeng@weiyuantool.com</code></li>
<li>Subject: <strong>Delete my account</strong></li>
<li>In the body, state the phone number or email you signed up with, so we can
locate the account. If you like, tell us why &mdash; we read it, but we will not
press you for it.</li>
</ul>

<p>To avoid deleting someone else&rsquo;s account by mistake, we only action requests
sent from the phone number or email you registered with, or from someone who can
prove they are the account holder. If we cannot verify this, we will reply and
explain what we still need.</p>

<h2>3. What gets deleted</h2>

<p>Once your identity is verified, we delete everything on our servers associated
with the account:</p>

<ul>
<li>The account itself (phone number / email, display name, avatar, WeChat and other
contact details)</li>
<li>Login tokens (invalidated immediately, including on every signed-in
device)</li>
<li>Pet profiles, entries, and reminders that had synced to the server</li>
<li>Co-care member relationships with family or friends</li>
<li>Any invitations this account sent that were never accepted</li>
</ul>

<h2>4. What is <em>not</em> deleted</h2>

<p><strong>The data on your phone.</strong> It lives on your device, so we cannot
reach it. To remove it, delete entries in the App or uninstall the App.</p>

<p><strong>Photos and your avatar.</strong> They were never uploaded, so there is
no copy on the server to delete.</p>

<p>If you want those gone as well, delete your pet&rsquo;s profile in the App or
uninstall the App &mdash; only you can do that.</p>

<h2>5. How long it takes</h2>

<p>We complete deletion within <strong>15 working days</strong> of receiving your
request and reply to confirm. After the account is closed it cannot be restored:
signing in again with the same phone number gives you a brand-new empty account, and
the old data does not come back.</p>

<h2>6. Deleting only part of it</h2>

<p>In most cases you do not need to close the whole account:</p>

<ul>
<li><strong>Just one pet&rsquo;s records</strong> &rarr; delete them directly in the
App (soft-deleted locally, no longer displayed)</li>
<li><strong>No longer sharing with someone</strong> &rarr; remove the member under
&ldquo;Co-care&rdquo;, or have them leave</li>
<li><strong>No longer syncing</strong> &rarr; sign out; the server data stays
untouched</li>
<li><strong>No longer want reminders</strong> &rarr; turn off the relevant reminders
in the App, or turn off notification permission in system settings</li>
</ul>

<h2>7. Contact us</h2>

<ul>
<li><strong>Operator:</strong> Linyi Weiyuan Tools</li>
<li><strong>Email:</strong> <code>zhuruipeng@weiyuantool.com</code></li>
<li><strong>Website:</strong> <a href="https://weiyuantool.com">https://weiyuantool.com</a></li>
</ul>

<p>The content of this page is consistent with section 7 of the
<a href="/legal/privacy?lang=en">Privacy Policy</a>; if the two ever disagree, this
page takes precedence.</p>
"""

PAGES = [
    {
        "src": "privacy-policy.html",
        "out": "privacy-policy.en.html",
        "title": "Privacy Policy · My Pet",
        "description": "Privacy Policy for the My Pet app: what is collected, how it is used, where it is stored, and how to manage it.",
        "body": PRIVACY_EN,
    },
    {
        "src": "terms-of-use.html",
        "out": "terms-of-use.en.html",
        "title": "Terms of Use · My Pet",
        "description": "Terms of Use for the My Pet app.",
        "body": TERMS_EN,
    },
    {
        "src": "account-deletion.html",
        "out": "account-deletion.en.html",
        "title": "Delete account · My Pet",
        "description": "How to delete your My Pet account and all server-side data.",
        "body": DELETION_EN,
    },
]


def main() -> int:
    check_only = "--check" in sys.argv

    # 样式从隐私政策中文版抽一次就够 —— 三个页面共用同一套。
    with open(os.path.join(LEGAL, "privacy-policy.html"), encoding="utf-8") as f:
        style = extract_style(f.read())

    for p in PAGES:
        out_path = os.path.join(LEGAL, p["out"])
        rendered = PAGE.format(
            title=p["title"],
            description=p["description"],
            style=style,
            body=p["body"].strip(),
        )

        if check_only:
            if not os.path.exists(out_path):
                print(f"✗ 缺少 {p['out']}", file=sys.stderr)
                return 1
            with open(out_path, encoding="utf-8") as f:
                if f.read() != rendered:
                    print(
                        f"✗ {p['out']} 与生成器不一致（正文改过？重跑 python3 tool/gen_legal_en.py）",
                        file=sys.stderr,
                    )
                    return 1
            print(f"  {p['out']}  ✓")
        else:
            with open(out_path, "w", encoding="utf-8") as f:
                f.write(rendered)
            print(f"  已生成 {p['out']}  ({len(rendered)} 字节)")

    if check_only:
        print("\n三个英文版页面与生成器一致。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
