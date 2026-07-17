# AGP Tracker 3D

An unofficial, visually stunning 3D community tracker for the Agent Grand Prix (agp.onlatch.com). This project provides a pure data visualization of the ongoing agent races using a dynamic, interactive 3D globe.

## ✨ Features

- **Interactive 3D Globe:** Visualizes racer data as thick, neon-colored planets orbiting a matte-black deep space void.
- **Pure Data Focus:** Stripped down to show only meaningful data points with equal sizing for perfect readability.
- **Racer Stats Card:** Click on any data point to view deep analytics, including points, questions, guesses, and spend ratios.
- **Social Sharing:** Instantly download a racer's stat card as a high-quality PNG image or share it directly to X (Twitter).
- **Background Sync:** Automatically pulls live data from the public AGP API in the background.

## 🛠️ Tech Stack

- **Frontend:** HTML, CSS, JavaScript, Three.js (WebGL), html2canvas
- **Backend:** Node.js, Express, better-sqlite3 (SQLite database)
- **Background Tasks:** node-cron

## 🚀 Getting Started Locally

1. **Clone the repository:**
   ```bash
   git clone https://github.com/YourUsername/agp-tracker-3d.git
   cd agp-tracker-3d
   ```

2. **Install dependencies:**
   ```bash
   npm install
   ```

3. **Start the server:**
   ```bash
   npm start
   ```

4. Open `http://localhost:3000` in your browser!

## 🚢 Deployment

This project requires a persistent filesystem (for the SQLite database) and support for background processes (for the cron jobs). 

**Recommended hosting:** [Render.com](https://render.com/) or [Railway.app](https://railway.app/). 
*Note: Serverless environments like Vercel or Netlify are not compatible with the SQLite backend.*
