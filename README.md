# Ceph Cluster Dashboard

A comprehensive solution for monitoring Ceph clusters with automated data collection and visualization. This system collects detailed information about Ceph clusters including OSDs, pools, WAL/DB mappings, and presents it in an intuitive web interface.

## Features

### Data Collection
- **Server Automation**: Remotely execute scripts on multiple Ceph servers
- **Secure Authentication**: SSH key-based authentication with sudo support
- **Comprehensive Info**: Collects detailed OSD, device, and pool information
- **BlueStore Support**: Maps WAL and DB devices to their respective OSDs

### Dashboard Interface
- **Cluster Overview**: View capacity, usage, OSD counts, and pool information
- **Server Statistics**: Break down storage usage by individual servers
- **OSD Details**: 
  - Full device paths in `/dev/sdX` format
  - Partition mappings
  - WAL and DB device connections
  - Searchable/filterable interface
- **Health Monitoring**: Warnings for BlueFS spillover and other issues
- **Real-time Refresh**: Update data dynamically

### Security & User Experience
- **Secure Credential Handling**: Passwords never stored to disk
- **Single Sign-on**: Enter credentials once for multiple servers
- **Automatic Launch**: One command to collect data and view dashboard
- **Responsive Design**: Works on desktop and mobile devices

## Components

This project includes multiple components:

1. `get_ceph_info.sh` - Bash script that runs on Ceph servers to collect cluster information
2. `fetch_ceph_data.py` - Python script to remotely execute data collection on servers
3. `app.py` - Flask web application that parses and displays collected data
4. `launch_ceph_dashboard.py` - All-in-one launcher script

## Installation

### Prerequisites
- Python 3.7+
- Flask
- Paramiko (for SSH connections)

### Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/ceph-details.git
   cd ceph-details
   ```

2. Install dependencies:
   ```bash
   pip install flask paramiko
   ```

3. Configure server access:
   ```bash
   # Create/edit config.conf file with your server details
   nano config.conf
   ```

## Usage

### Quick Start

The easiest way to use the dashboard is with the launcher script:

```bash
python launch_ceph_dashboard.py
```

This will:
1. Prompt for SSH key and sudo passwords
2. Connect to all servers in your config file
3. Run the collection script on each server
4. Download the resulting output files
5. Launch the web dashboard
6. Open your browser to view the dashboard

### Manual Operation

If you prefer to run each step separately:

1. Fetch data from servers:
   ```bash
   python fetch_ceph_data.py
   ```

2. Launch the web dashboard:
   ```bash
   python app.py
   ```

3. Open your browser to http://localhost:5000

## Configuration

### Server Configuration

Create a `config.conf` file with your server details:

```ini
[ssh]
# SSH connection details
username = ceph_admin
key_file = ~/.ssh/ceph_id_rsa
key_requires_password = true

[servers]
# List of servers to connect to (name = IP address)
arh-ibstorage1-ib = 192.168.169.201
arh-ibstorage2-ib = 192.168.169.202
arh-ibstorage3-ib = 192.168.169.203
arh-ibstorage4-ib = 192.168.169.204

[paths]
# Remote path to the get_ceph_info.sh script
remote_script_path = /root/get_ceph_info.sh
```

### Dashboard Customization

- **Color Scheme**: Edit `static/style.css` to change dashboard appearance
- **Layout**: Modify `templates/index.html` to adjust dashboard layout
- **Data Processing**: Update parsing patterns in `app.py` if output format changes

## Project Structure

```
ceph-details/
├── app.py                      # Web application
├── config.conf                 # Server configuration
├── fetch_ceph_data.py          # Remote data collection script
├── get_ceph_info.sh            # Bash script for Ceph data collection
├── launch_ceph_dashboard.py    # All-in-one launcher
├── output/                     # Data output directory
│   └── ceph-details-output-*.md   # Output files
├── static/                     # CSS and static assets
│   └── style.css
├── templates/                  # HTML templates
│   └── index.html
└── README.md                   # This file
```

## Troubleshooting

### Data Collection Issues

- **SSH Connection Failures**: Verify server IPs and SSH key paths
- **Script Execution Errors**: Ensure the script has proper permissions
- **No Output Files**: Check remote_script_path is correct

### Dashboard Issues

- **Missing Data**: Ensure output files exist in the output/ directory
- **Flask Errors**: Check terminal output for error messages
- **Parsing Problems**: Check if the output format changed

## Security Notes

- SSH key and sudo passwords are requested at runtime
- Passwords are never stored to disk
- Passwords are cleared from memory after use
- Use server accounts with appropriate permissions