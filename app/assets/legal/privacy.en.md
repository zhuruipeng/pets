# My Pet · Privacy Policy

**Effective date:** 30 September 2026
**Last updated:** 6 October 2026

This policy explains what information "My Pet" (the "App") collects, how we use it,
where it is stored, and how you can manage it. The operator is **Linyi Weiyuan Tools**.

> This policy is written to match the App's actual, current behaviour. If something is
> not in the App — advertising SDKs, analytics tracking, server-side push, AI analysis —
> it is not listed here. Describing collection that does not exist is worse than
> omitting it: if a store audit finds the mismatch, the policy loses your trust for good.
>
> The one exception is **crash logs** (see 2.4), which really are uploaded
> automatically. That is stated plainly here rather than papered over with an
> argument that crash logs "aren't analytics".

---

## 1. The short version

**Your pet's data stays on your phone by default.** It is only sent to the server for
your region after you deliberately sign in. Photos are never uploaded.

---

## 2. What we collect

### 2.1 Information you enter

| Content | Purpose | Required? |
| --- | --- | --- |
| Pet profile (name, breed, sex, birthday, weight, colour, neuter status, microchip number, personality tags) | Build the profile; generate vaccine and deworming reminders | Yes — the App cannot work without it |
| Entries (weight, vaccine, deworming, medication, vet visits, feeding, bathroom, notes) | Timeline and health overview | Yes |
| Pet photos | Profile avatar, entry attachments, lost-pet poster | Optional |
| Walk traces (latitude/longitude) | Record walk distance and route | Optional (requires location permission) |

### 2.2 Account and contact details (only after you sign in)

| Content | Purpose |
| --- | --- |
| Phone number or email | Sign in, account recovery, co-care invitations |
| Display name | Lets others recognise you in co-care |
| WeChat / other contact details | **Used only on the lost-pet poster** — printed on the card so whoever finds your pet can reach you |

### 2.3 What we do **not** collect

- No contacts, SMS messages, or call logs
- No device identifiers (IMEI / OAID / advertising ID)
- No behavioural tracking, no user profiling, no advertising SDKs
- No third-party analytics services
- We do not read your other photos — we only take the single image you select in the
  system photo picker

### 2.4 Crash logs (the only thing uploaded automatically)

When the App crashes, it records an error report and sends it to our server **the next
time you open the App**, so we can fix the problem. It contains:

- the error type and message
- the program stack trace (which line went wrong)
- your App version, your region, and your device OS version

**It does not contain** your account, phone number, pet's name, entries, photos,
or anything that could identify you. It includes no device identifier.

Its only purpose is to locate and fix crashes. **It is never used to analyse how you
use the App.**

You can review and delete these records under "My page -> Report a problem";
anything you delete there will no longer be uploaded.

---

## 3. Where your data is stored

The App is **local-first**, and the two regions run on separate infrastructure:

| Data | Location |
| --- | --- |
| Pet profile, entries, reminders, traces | **On-device database** (the App's private directory, unreadable by other apps) |
| Photos, avatar | **On-device files** (the App's private directory). **Never uploaded.** |
| Account, display name, contact details | Mainland China users → servers located in Mainland China; overseas users → overseas servers |

**The two regions are fully isolated, with no cross-border transfer.** Personal data of
users in Mainland China never leaves the country, and personal data of overseas users is
never sent back into China. This is a structural decision made to avoid cross-border
compliance review entirely — not an assessment written after the fact.

---

## 4. Who we share your data with

**Nobody.** Specifically:

- We do not sell, share, or transfer your data to advertisers or data brokers
- We do not integrate third-party SDKs for payments, social features, or analytics
- We disclose data only where **the law explicitly requires it** (for example, a court
  order), and we will tell you within whatever bounds the law allows

---

## 5. Third-party services

| Service | When it is used | What is sent |
| --- | --- | --- |
| SMS / email provider | When you request a sign-in code | Your phone number or email (used only to deliver the code) |
| In-app update check | When you open the App | Requests a version manifest only; carries no personal information |
| Map tiles (overseas version only) | When you view a walk trace | Map tile requests include the **coordinates of the area you are viewing** — this is inherent to how map services work |

> The Mainland China version **does not render map tiles** (map display inside the
> mainland requires a survey licence), so no such request is made.

---

## 6. Permissions

Every permission this App requests maps to a feature you can see. Declining one does
not affect the others:

| Permission | Purpose | If you decline |
| --- | --- | --- |
| Notifications | Due-date reminders for vaccines, deworming, check-ups | No reminders; everything else works |
| Camera / Photo library | Profile avatar, photos on entries | Cannot add images |
| Location (while using only) | Record walk traces and distance | No traces; you can still log walks manually |
| Network | Sign in, multi-device sync, update checks | Single-device use only |
| Launch at startup | Rebuild scheduled reminders after a restart | Reminders are lost after a restart |

We do **not** request contacts, SMS, call logs, or continuous background location.

---

## 7. Retention and deletion

- **On-device data:** deleted when you uninstall the App. You can also delete entries
  individually inside the App (deletion is soft: the item is marked deleted locally and
  hidden from view).
- **Account:** sign out under "Me → Data sync". After signing out, local data is kept but
  no longer uploaded.
- **Server-side data:** to close your account and delete server-side data, email
  `zhuruipeng@weiyuantool.com` with the phone number or email you signed in with. We
  complete the deletion and reply within **15 working days**. Deletion cannot be undone.

---

## 8. Security

- The sign-in token lives only on your device; the server stores a **hash** of it (the
  server cannot retrieve the plaintext token either)
- Signing out immediately invalidates that token on the server
- All traffic is over HTTPS
- Photos never leave the phone, so there is no cloud exposure to worry about

> One point worth being explicit about: the sign-in token is currently stored in the
> App's private directory. On unjailbroken / unrooted devices other apps cannot read
> that directory, but it is not a system-level keychain. This is on our improvement list.

---

## 9. Children

The App is intended for pet owners, not for minors, and we do not knowingly collect
personal information from children. If a guardian finds that a minor has used the App
without consent, contact us and we will delete the relevant data.

---

## 10. Your rights

Whether you are in Mainland China or overseas, you can:

- See what data we hold about you (visible directly in the App, or ask us for an export)
- Correct inaccurate data (editable directly in the App)
- Delete data (delete in the App, or ask us to close your account)
- Refuse or withdraw consent (turn the permission off in system settings)

Overseas users have additional rights under GDPR / CCPA (portability, the right to
object to processing, non-discrimination, and so on). To exercise any of them, email the
address below.

---

## 11. Changes to this policy

When functionality changes — for example, if we later add cloud photo sync or paid
features — we will update this policy and notify you in the App. Continuing to use the
App means you accept the updated version.

---

## 12. Contact us

- **Operator:** Linyi Weiyuan Tools
- **Email:** `zhuruipeng@weiyuantool.com`
- **Website:** https://weiyuantool.com

We respond to personal-information questions within **15 working days**.
