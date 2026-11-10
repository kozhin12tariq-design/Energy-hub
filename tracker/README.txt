DAILY TEAM TRACKER — standalone app
Teams 20, 21, 26, 27, 29 · smart meters · Suli

WHAT IT IS
A single web app that runs entirely on your own device. No account, no internet
needed after the first load, nothing sent anywhere. Your entries are stored in
the browser on the device you use.


THE QUICK WAY (no hosting)
Open Team_Tracker.html on the phone or the computer. It works straight away.
Chrome on Android: ... menu > Add to Home screen. Nothing else to do.


THE PROPER APP (recommended — gives a real icon, offline launch, full screen)
You need to put these files on any web address. Two free options:

  Netlify Drop — https://app.netlify.com/drop
    1. Zip this folder (or drag the folder itself onto the page).
    2. Drop it there. You get a link like https://something.netlify.app
    3. Open that link on the phone, Chrome menu > Install app / Add to Home screen.

  GitHub Pages
    1. Create a repository, upload these files to it.
    2. Settings > Pages > Branch: main, folder: / (root). Save.
    3. Open the address it gives you, then Install app on the phone.

Either way the app then launches full screen from the home screen and works
with no signal.


FILES
  index.html              the whole app (open this one)
  manifest.webmanifest    name, icon and colours for the installed app
  sw.js                   makes it work offline
  icon-192.png            home-screen icon
  icon-512.png            home-screen icon, large
  icon-512-maskable.png   Android adaptive icon


USING IT
  Day tab     Pick the date at the top. Five team cards. Tap "Main reason" and
              choose from the eight standard reasons; type a free comment under
              it. A team you do not touch counts as on target. It saves itself.
  Month tab   Count of each reason per team, then every entry day by day.
  PDF         Opens the phone's print sheet — choose "Save as PDF".
  Excel       A real .xlsx with three sheets: Tracker (the monthly grid, days
              down and teams across), Summary (the counts), Log (one row per
              entry).
  CSV         The plain list.
  Backup file Writes everything to a .json file. This is how you move the data
              to another phone or computer — Restore backup reads it back.


IMPORTANT
The data lives in the browser on that one device. It is not shared between
phones and it is not backed up anywhere. Take a Backup file now and then, and
before changing phone, clearing browser data or reinstalling.

To change the list of teams or the list of reasons, open index.html in any text
editor and edit the TEAMS and REASONS lines near the top of the script.
