# Installing Media Helper on a church Mac

You need: the Mac, an internet connection (once, for the first start), and the file **Media Helper.app**
(or the zip `MediaHelper-<version>.zip`, which you double-click to unzip).

## Install

1. Drag **Media Helper** into the **Applications** folder. (Do this before opening it. The app can only
   update itself once it lives in Applications.)
2. **First open only: right-click (or Control-click) Media Helper and choose Open**, then click **Open**
   in the box that appears. The app isn't signed with a paid Apple developer certificate, so a plain
   double-click is blocked the first time. After that it opens normally.
   * If you see "Media Helper can't be opened": open **System Settings ▸ Privacy & Security**, scroll down,
     and click **Open Anyway** next to the Media Helper message.
3. The window says **"Getting ready… (one-time setup, needs internet)"**. Wait a minute or so while the
   Mac downloads what it needs. When the two tabs become active, it's ready.
   * If it says it couldn't finish, check the internet connection and click **Try Again**.
4. The first time you save to Downloads, macOS may ask whether Media Helper can access files in your
   Downloads folder. Click **OK**.

After the first setup it works without special steps, and it keeps itself up to date: it refreshes
its YouTube downloader every day or so, and shows **"Version X is available — Install"** at the top of the
window when a new version of the app is ready. (Installing only happens when you click, and only when nothing
is downloading or converting.)

## Using it

* **Download from YouTube:** paste links (one per line), choose Audio or Video, click **Download**.
* **Video → Audio:** drag video files onto the window, or click **Choose Files…**.
* **Save to:** shows where files go. Click **Change…** to pick another folder.

## If something doesn't work

* *"YouTube is limiting requests from this Mac"*: wait a few minutes and try again.
* *"That video is unavailable or private"*: the video can't be downloaded; try another.
* Anything else: try again; if it keeps happening, check for updates (Media Helper menu ▸ **Check for Updates…**).
* The small grey line at the bottom of the window lists the version of Media Helper and of its helper tools,
  handy when asking for help.

## Removing it

Drag Media Helper from Applications to the Bin. To also remove its helper programs, delete the folder
`~/Library/Application Support/Media Helper`.
