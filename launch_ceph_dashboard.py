#!/usr/bin/env python3
"""
Launcher script for Ceph Dashboard
1. Fetches data from Ceph servers
2. Launches the web app to display the data
"""

import os
import sys
import subprocess
import webbrowser
import socket
import time
import threading

def get_free_port():
    """Find a free port on the system to run the app."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(('', 0))
        return s.getsockname()[1]

def fetch_data():
    """Run the data fetching script."""
    print("=" * 60)
    print("Step 1: Fetching Ceph cluster data from servers...")
    print("=" * 60)
    
    try:
        # Run fetch_ceph_data.py and wait for it to complete
        subprocess.run([sys.executable, "fetch_ceph_data.py"], check=True)
        print("\nData collection completed successfully.")
        return True
    except subprocess.CalledProcessError:
        print("\nError: Failed to fetch data from servers.")
        return False
    except FileNotFoundError:
        print("\nError: fetch_ceph_data.py not found in the current directory.")
        return False

def launch_webapp(port):
    """Launch the Flask web app on the specified port."""
    env = os.environ.copy()
    env["FLASK_APP"] = "app.py"
    
    # Start Flask app with the specified port
    process = subprocess.Popen(
        [sys.executable, "-m", "flask", "run", "--host=0.0.0.0", f"--port={port}"],
        env=env
    )
    
    return process

def open_browser(url, delay=2):
    """Open the browser after a short delay to allow the app to start."""
    def _open_browser():
        time.sleep(delay)
        webbrowser.open(url)
    
    thread = threading.Thread(target=_open_browser)
    thread.daemon = True
    thread.start()

def main():
    """Main function to orchestrate data fetching and app launching."""
    # Ensure we have the required files
    if not os.path.exists("app.py"):
        print("Error: app.py not found in the current directory.")
        print("Make sure you're running this script from the project directory.")
        return 1
    
    # Step 1: Fetch data from Ceph servers
    if not fetch_data():
        print("Would you like to continue and launch the app anyway? (y/n)")
        response = input().strip().lower()
        if response != 'y':
            return 1
    
    # Step 2: Launch the web app
    print("\n" + "=" * 60)
    print("Step 2: Launching Ceph Dashboard web app...")
    print("=" * 60)
    
    # Get a free port to run the app
    port = get_free_port()
    
    # Construct the URL
    local_ip = socket.gethostbyname(socket.gethostname())
    urls = [
        f"http://localhost:{port}/",
        f"http://127.0.0.1:{port}/",
        f"http://{local_ip}:{port}/"
    ]
    
    # Launch the app
    app_process = launch_webapp(port)
    
    # Check if app is running
    time.sleep(2)
    if app_process.poll() is not None:
        print("Error: Failed to start the web app.")
        return 1
    
    # Print access URLs
    print("\nCeph Dashboard is now running!")
    print("\nYou can access it at:")
    for url in urls:
        print(f"  - {url}")
    
    # Open browser automatically
    open_browser(urls[0])
    
    print("\nPress Ctrl+C to stop the dashboard...")
    
    try:
        # Keep the script running until user presses Ctrl+C
        app_process.wait()
    except KeyboardInterrupt:
        print("\nStopping Ceph Dashboard...")
        app_process.terminate()
        app_process.wait()
        print("Dashboard stopped.")
    
    return 0

if __name__ == "__main__":
    sys.exit(main())