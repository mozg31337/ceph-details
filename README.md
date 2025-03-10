# Ceph Cluster Dashboard

A comprehensive solution for monitoring Ceph clusters with automated data collection and visualization. This system collects detailed information about Ceph clusters including OSDs, pools, WAL/DB mappings, and presents it in an intuitive web interface.

## Features

### Data Collection
- **Server Automation**: Remotely execute scripts on multiple Ceph servers
- **Secure Authentication**: SSH key-based authentication with sudo support
- **Comprehensive Info**: Collects detailed OSD, device, and pool information
- **BlueStore Support**: Maps WAL and DB devices to their respective OSDs
- **Multi-key Type Support**: Compatible with ED25519, RSA, ECDSA, and DSS SSH keys

### Dashboard Interface
- **Cluster Overview**: View capacity, usage, OSD counts, and pool information
- **Server Statistics**: Break down storage usage by individual servers
- **OSD Details**: 
  - Full device paths in `/dev/sdX` format
  - Partition mappings
  - WAL and DB device connections
  - Searchable/filterable interface
- **OSDs by Server & Type**: Organized view of OSDs grouped by server and device type (HDD/SSD)
- **LVM Support**: Properly displays complex LVM setups including logical volumes
- **Health Monitoring**: Warnings for BlueFS spillover and other issues
- **Real-time Refresh**: Update data dynamically

### Security & User Experience
- **Secure Credential Handling**: Passwords never stored to disk
- **Single Sign-on**: Enter credentials once for multiple servers
- **Automatic Launch**: One command to collect data and view dashboard
- **Responsive Design**: Works on desktop and mobile devices
- **Interactive Search**: Filter OSDs and devices across all servers
- **Visual Classification**: Color-coded sections for HDD and SSD devices
- **Flexible Shell Support**: Auto-detects various shell prompts for better compatibility

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
│   ├── base.html               # Base template with navigation
│   ├── index.html              # Home page template
│   └── osds_by_server.html     # OSDs by server and type template
└── README.md                   # This file
```

## View Descriptions

### Home Page
The main dashboard showing an overview of all servers, with detailed sections for:
- Cluster status and health
- OSD tree structure
- Local OSD list
- Pool usage statistics
- Storage device listings

### OSDs by Server & Type
A dedicated view that organizes all OSDs across your Ceph cluster by:
- Server (each server gets its own section)
- Device type (separate tables for SSDs and HDDs)
- Complete information including:
  - OSD ID
  - Device path
  - Size
  - Model
  - DB Device (with size)
  - WAL Device (with size)
- Interactive search box to filter by any attribute
- Visual differentiation between SSD and HDD devices
- Support for complex LVM configurations

## API Endpoints

The dashboard provides JSON API endpoints for programmatic access:

- `/api/servers` - Get information for all servers
- `/api/server/{server_name}` - Get information for a specific server

## Troubleshooting

### Data Collection Issues

- **SSH Connection Failures**: Verify server IPs and SSH key paths
- **SSH Key Type Issues**: The script now supports multiple key types (ED25519, RSA, ECDSA, DSS)
- **Shell Prompt Detection**: The script auto-detects various shell prompts for better compatibility
- **Script Execution Errors**: Ensure the script has proper permissions
- **No Output Files**: Check remote_script_path is correct
- **LVM Configuration Issues**: The script now properly handles complex LVM setups

### Dashboard Issues

- **Missing Data**: Ensure output files exist in the output/ directory
- **Flask Errors**: Check terminal output for error messages
- **Parsing Problems**: Check if the output format changed
- **Table Display Issues**: Verify CSS is properly loaded

## Security Notes

- SSH key and sudo passwords are requested at runtime
- Passwords are never stored to disk
- Passwords are cleared from memory after use
- Use server accounts with appropriate permissions