# Donna — High-Level Design (Layman Edition)

## What Does Donna Do?

Donna is like a **time detective** that sits in your menu bar and watches:
- Which app you're using (Chrome, VS Code, Spotify, etc.)
- Whether you're actually using your Mac or if it's sitting idle
- How much time you spend being productive vs getting distracted

Then it gives you reports like: "You spent 3 hours coding today, 1 hour on YouTube, and were idle for 30 minutes."

---

## The Big Picture — How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                       YOUR MAC                               │
│                                                              │
│  ┌──────────┐   Every 5 seconds, Donna asks:                │
│  │  Donna   │   "Which app is in front right now?"          │
│  │  (⏱)    │   "Has the user touched anything recently?"   │
│  └────┬─────┘                                                │
│       │                                                      │
│       ├──> Checks: Safari is in front                       │
│       ├──> Checks: Last mouse click was 10 seconds ago      │
│       │                                                      │
│       └──> Saves: "Safari, 5 seconds, not idle"             │
│                    ↓                                         │
│            ┌───────────────┐                                 │
│            │  data/ folder │  (Stored as JSON files)         │
│            │               │                                 │
│            │ 2026-02-12.json: {                              │
│            │   "Safari": 3600 seconds,                       │
│            │   "VS Code": 7200 seconds,                      │
│            │   ...                                           │
│            │ }                                               │
│            └───────────────┘                                 │
└─────────────────────────────────────────────────────────────┘
```

---

## The donna/ Folder — Each File's Job

Think of these files like **workers in a factory**, each with a specific job:

### 1. **app.py** — The Boss (Menu Bar App)
**What it does:** Creates the little icon in your menu bar with all the buttons.

**Layman explanation:**
- This is the "face" of Donna that you see and click
- When you click "Start Tracking," this file tells everyone else to start working
- When you click "Today's Summary," it asks other workers to gather the data and show it to you

**Technical:** Uses `rumps` library to create a macOS menu bar application with callbacks for user interactions.

---

### 2. **tracker.py** — The Observer (The Spy)
**What it does:** Every 5 seconds, looks at your screen and writes down what you're doing.

**Layman explanation:**
- Like a security guard doing rounds every 5 seconds
- Checks: "What app is in front?" → writes it down
- Checks: "Is the user active or idle?" → writes that too
- Keeps a running total for the day

**Technical:** Polls `NSWorkspace.frontmostApplication()` every poll interval, accumulates time in a `DailyRecord` dataclass, handles day rollovers.

---

### 3. **idle_detector.py** — The Motion Sensor
**What it does:** Detects if you've stopped using your Mac.

**Layman explanation:**
- Like those automatic lights that turn off when you leave the room
- Asks macOS: "How long since the last keyboard press or mouse move?"
- If it's been 2+ minutes → you're marked as "idle"

**Technical:** Uses Quartz Event Services (`CGEventSourceSecondsSinceLastEventType`) to read HID idle time from macOS.

---

### 4. **storage.py** — The Filing Cabinet
**What it does:** Saves data to disk and loads it back.

**Layman explanation:**
- Saves today's tracking data to a file called `2026-02-12.json`
- Can load old files to show you "what did I do last Tuesday?"
- Can export to CSV if you want to open it in Excel

**Technical:** JSON serialization/deserialization, file I/O to `data/` directory, CSV export helper.

---

### 5. **categories.py** — The Classifier (The Judge)
**What it does:** Decides if an app is "productive" or "distracting."

**Layman explanation:**
- Has a built-in list: "VS Code = productive, YouTube = distracting"
- When you open Safari, it checks the list and tags it
- You can override: "Actually, I use Safari for work docs, mark it productive"

**Technical:** Dictionary-based mapping (app name → category), persists user overrides to `data/categories.json`, supports productive/distracting/neutral classification.

---

### 6. **summary.py** — The Reporter (Makes It Pretty)
**What it does:** Takes raw numbers and turns them into human-readable text.

**Layman explanation:**
- Raw data: `{ "VS Code": 7200 seconds }`
- Summary: "✅ Active: 2h 0m — Top app: VS Code"
- Adds emojis, formats time nicely, shows category breakdowns

**Technical:** String formatting, time conversion (seconds → hours/minutes), integration with `CategoryManager` for emoji annotations.

---

### 7. **trends.py** — The Analyst (The Historian)
**What it does:** Shows you patterns over the last 7 days.

**Layman explanation:**
- Loads the last 7 days of data
- Draws ASCII bar charts showing "Monday: 5h active, Tuesday: 3h active..."
- Shows your "productivity score" (% of time spent on productive apps)

**Technical:** Aggregates multiple `DailyRecord` objects, calculates weekly totals/averages, renders ASCII bar charts with proportional width.

---

### 8. **autostart.py** — The Alarm Clock
**What it does:** Makes Donna launch automatically when you log into your Mac.

**Layman explanation:**
- Tells macOS: "Hey, every time this user logs in, run Donna"
- Creates a special file (`plist`) that macOS checks on startup
- You can turn it on/off from the menu

**Technical:** Creates/removes a LaunchAgent plist at `~/Library/LaunchAgents/`, uses `launchctl` to load/unload the agent, `plistlib` for XML generation.

---

## How They Work Together — The Flow

### When You Click "Start Tracking":

```
   [app.py]  "User clicked Start!"
      ↓
   [app.py]  Starts a timer that fires every 5 seconds
      ↓
   [tracker.py]  Gets called every 5 seconds
      ↓
   [idle_detector.py]  "Are they idle?"
      ↓
   [tracker.py]  "Nope, they're active. What app?"
      ↓
   macOS tells tracker.py: "Safari is in front"
      ↓
   [tracker.py]  Adds 5 seconds to Safari's total
      ↓
   [categories.py]  "Safari = distracting"
      ↓
   [tracker.py]  Updates the DailyRecord object in memory
      ↓
   [app.py]  Updates menu bar title: "⏱ 45m active · 🔴12m"
```

### Every 60 seconds (auto-save):

```
   [app.py]  "Time to save!"
      ↓
   [storage.py]  "Give me today's data"
      ↓
   [tracker.py]  Hands over the DailyRecord
      ↓
   [storage.py]  Writes to data/2026-02-12.json
```

### When You Click "Today's Summary":

```
   [app.py]  "User wants a summary!"
      ↓
   [summary.py]  "Give me today's data"
      ↓
   [tracker.py]  Provides the DailyRecord
      ↓
   [summary.py]  Formats it nicely with emojis
      ↓
   [app.py]  Shows a pop-up window with the summary
```

---

## Data Flow Diagram

```
┌──────────────┐
│   macOS API  │  (tells us which app is in front)
└──────┬───────┘
       │
       ↓
┌──────────────┐
│  tracker.py  │  ← polls every 5 sec, builds DailyRecord
└──────┬───────┘
       │
       ├─→ [categories.py] tags apps as productive/distracting
       │
       ├─→ [idle_detector.py] checks if user is idle
       │
       ↓
┌──────────────┐
│ DailyRecord  │  (in-memory object with all today's data)
│   object     │
└──────┬───────┘
       │
       ├─→ [storage.py] saves to JSON every 60 sec
       │
       ├─→ [summary.py] formats for display
       │
       ├─→ [trends.py] aggregates weekly stats
       │
       ↓
┌──────────────┐
│   app.py     │  Shows everything in the menu bar
└──────────────┘
```

---

## Key Concepts

### 1. Polling
**Layman:** Checking something repeatedly at regular intervals.  
**Technical:** A while-loop or timer that executes a function every N seconds.

### 2. DailyRecord
**Layman:** A digital notepad where we write down everything you did today.  
**Technical:** A Python `dataclass` that holds:
- `date`: which day this is
- `active_seconds`: total time you were active
- `idle_seconds`: total time you were idle
- `app_seconds`: a dictionary mapping app names to seconds spent

### 3. Callback
**Layman:** A function that runs when something happens (like clicking a button).  
**Technical:** A function reference passed to another function, invoked asynchronously when an event occurs.

### 4. Menu Bar App
**Layman:** Those little icons at the top-right of your Mac screen (Wi-Fi, battery, etc.).  
**Technical:** A persistent macOS application without a main window, using `NSStatusBar` API (via `rumps` wrapper).

---

## Why This Architecture?

### Separation of Concerns
- Each file has **one job** and does it well
- If you want to change how time is formatted, you only edit `summary.py`
- If you want to change the idle threshold, you only edit `idle_detector.py`

### Modularity
- You can test `tracker.py` without the menu bar
- You can run `trends.py` from the command line
- Each piece can be swapped out or improved independently

### Maintainability
- Small files (100-200 lines each) are easier to understand
- Clear naming: `idle_detector.py` does exactly what it says
- Adding a new feature doesn't require touching every file

---

## Next Steps

Now that you understand the big picture, you can:
1. **Pick a file** and read its code (start with `idle_detector.py` — it's the simplest)
2. **Trace a flow** — follow what happens when you click "Start Tracking"
3. **Modify something** — change the idle threshold from 120 to 60 seconds
4. **Add a feature** — maybe add a "breaks taken today" counter

Let me know which part you want to dive deeper into!
