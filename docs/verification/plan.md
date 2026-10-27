# Letting anyone connect their calendar to Lyra

*28 October 2026. Goal: anyone can connect Google or Microsoft with a plain sign-in. No warning screens, no user cap,
no IT approval.*

## Where things stand (checked today)

**Google** (Cloud project `aidos-workspace`):
- Published ("In production") and open to any Google account. 1 of 100 user places used.
- The sign-in screen is shared with your other tools. It's named **"Leo"**, its homepage is your Instagram, and
  its privacy policy is a Google Doc. Google can't verify any of that, because you don't own instagram.com or
  google.com.
- Calendar access isn't declared, so nothing has been sent to Google for review.
- Result for other people: an "unverified app" warning, and only 99 more people can ever connect.

**Microsoft** ("Lyra" in your Default Directory):
- Personal Microsoft accounts and most work accounts can connect now.
- Companies that allow only verified publishers must get their IT admin to approve Lyra. Microsoft recommends
  that setting, so it's common.

**What you already have:** your own domain (Cloudflare, hosted on Vercel). Google and Microsoft both need a
domain you own, and this one works.

## Google: about 1–2 hours of setup, then Google reviews it

Google takes about 2–3 working days to check the name and logo. Calendar access can take a few weeks.

1. **Ask for less.** I switch Lyra to Google's narrowest calendar permission, "see events on calendars you own".
   Google reviewers ask for the narrowest permission that works. You sign in to Google once to check it.
2. **A Lyra page and privacy policy** at your own domain/lyra and /lyra/privacy. Drafts are in
   [lyra-page.md](lyra-page.md) and [privacy-policy.md](privacy-policy.md). I add them to your site and publish,
   once you've read them and said yes.
3. **Prove you own your own domain** to Google, in Search Console. Google adds one record to your Cloudflare
   settings, and you click Allow.
4. **A separate Google project just for Lyra,** named "Lyra", with its logo, the new page and the calendar
   permission declared. This leaves Leo and your other tools as they are. I set it up in Chrome. Then I put
   the new details into Lyra and reinstall. You reconnect Google once.
5. **A logo.** Google needs a square Lyra logo, and Lyra doesn't have one yet. I'll design some options for you
   to pick from.
6. **A short screen recording** of connecting Google in Lyra. It must show Google's permission screen in
   English, then the Coming up list. I'll give you a shot list. You record it and upload it to YouTube as
   unlisted.
7. **Submit for review.** I fill in the form and you approve sending it.

## Microsoft: slower, and needs your business details

Microsoft verifies the business behind an app, not the app itself. It's free, but most of it is in your name:

1. **Join Microsoft's partner programme (Partner Center)** as your business. You need your ABN, business name
   and address, and an email address at your own domain (Cloudflare can forward it to your Gmail). Microsoft
   checks the business, usually in a few days.
2. **A work account in your Microsoft directory** at your own domain. Lyra was registered with your personal
   Microsoft account, and Microsoft won't verify apps registered that way. So I register Lyra again under the
   new work account.
3. **Link the two:** I enter your partner ID on the new Lyra registration, and Lyra shows Microsoft's blue
   "verified" tick.

**What it fixes, and what it doesn't:** the "unverified" warning goes, and so does Microsoft's automatic block on
new unverified apps. Some companies still let staff approve only basic permissions such as name and email. Their
IT admin must approve calendar access once for the whole company. That's true for every calendar app, Granola
included. So Microsoft verification helps, but it's less urgent than Google.

## Two things to settle first

- **Meeting titles and Claude.** If you start a recording with Join, the calendar event's title goes to Claude
  with the transcript. Google allows this for a feature people can see, if the policy says so. The draft says
  so. Google also forbids that data being used to train AI. That depends on each user's own Claude settings,
  which Lyra can't control. The safer option is to keep calendar titles away from Claude. It's a small change.
- **How people get Lyra.** Google's reviewers expect the page to say how to get the app. Right now Lyra is
  built only for your Mac. For now the draft doesn't say how to download it.
