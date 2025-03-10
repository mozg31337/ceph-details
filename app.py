#!/usr/bin/env python3
"""
Ceph Cluster Dashboard App
Flask application for displaying Ceph cluster information collected by get_ceph_info.sh
"""

import os
import re
import glob
import configparser
from flask import Flask, render_template, jsonify

# Read configuration
config = configparser.ConfigParser()
config_path = os.path.join(os.path.dirname(__file__), 'config.conf')
if os.path.exists(config_path):
    config.read(config_path)
else:
    print(f"Warning: Config file {config_path} not found. Using defaults.")

# Get app settings with defaults
APP_PORT = config.getint('app', 'port', fallback=54321)
APP_HOST = config.get('app', 'host', fallback='0.0.0.0')
APP_DEBUG = config.getboolean('app', 'debug', fallback=True)

app = Flask(__name__)

def find_output_files():
    """Find all output files in the output directory."""
    # Look for files in the output directory
    output_dir = os.path.join(os.path.dirname(__file__), 'output')
    if not os.path.exists(output_dir):
        os.makedirs(output_dir)
    
    # Get all markdown files
    file_pattern = os.path.join(output_dir, 'ceph-details-output-*.md')
    return sorted(glob.glob(file_pattern))

def parse_output_file(file_path):
    """Parse a single output file and extract relevant information."""
    with open(file_path, 'r') as f:
        content = f.read()
    
    # Extract server name from filename
    server_name = os.path.basename(file_path).replace('ceph-details-output-', '').replace('.md', '')
    
    # Extract sections using regular expressions
    status_match = re.search(r'### Cluster Status\s*```\s*(.*?)\s*```', content, re.DOTALL)
    status = status_match.group(1) if status_match else "Not available"
    
    health_match = re.search(r'### Cluster Health\s*```\s*(.*?)\s*```', content, re.DOTALL)
    health = health_match.group(1) if health_match else "Not available"
    
    version_match = re.search(r'### Ceph Version\s*```\s*(.*?)\s*```', content, re.DOTALL)
    version = version_match.group(1) if version_match else "Not available"
    
    # Extract OSD information
    osd_tree_match = re.search(r'### OSD Tree\s*```\s*(.*?)\s*```', content, re.DOTALL)
    osd_tree = osd_tree_match.group(1) if osd_tree_match else "Not available"
    
    # Extract local OSDs
    local_osds_match = re.search(r'### Local OSDs\s*This server hosts the following OSDs: (.*?)\n', content)
    local_osds = local_osds_match.group(1) if local_osds_match else "None found"
    
    # Extract OSD device mapping
    osd_mapping_match = re.search(r'### OSD to Device Mapping.*?\n.*?\n\|(.*?)\n\|(.*?)\n((?:\|.*\n)+)', content, re.DOTALL)
    osd_mapping = []
    
    if osd_mapping_match:
        headers = [h.strip() for h in osd_mapping_match.group(1).split('|')]
        rows = osd_mapping_match.group(3).strip().split('\n')
        
        for row in rows:
            columns = [col.strip() for col in row.split('|')]
            if len(columns) > len(headers):
                osd_data = {headers[i]: columns[i+1] for i in range(len(headers))}
                osd_mapping.append(osd_data)
    
    # Extract OSD metadata
    osd_metadata_match = re.search(r'### OSD Metadata.*?\n.*?\n\|(.*?)\n\|(.*?)\n((?:\|.*\n)+)', content, re.DOTALL)
    osd_metadata = []
    
    if osd_metadata_match:
        headers = [h.strip() for h in osd_metadata_match.group(1).split('|')]
        rows = osd_metadata_match.group(3).strip().split('\n')
        
        for row in rows:
            columns = [col.strip() for col in row.split('|')]
            if len(columns) > len(headers):
                osd_data = {headers[i]: columns[i+1] for i in range(len(headers))}
                osd_metadata.append(osd_data)
    
    # Extract disk information
    disk_info_match = re.search(r'### Detailed Disk Information\s*\n\s*\n\|(.*?)\n\|(.*?)\n((?:\|.*\n)+)', content, re.DOTALL)
    disk_info = []
    
    if disk_info_match:
        headers = [h.strip() for h in disk_info_match.group(1).split('|')]
        rows = disk_info_match.group(3).strip().split('\n')
        
        for row in rows:
            columns = [col.strip() for col in row.split('|')]
            if len(columns) > len(headers):
                disk_data = {headers[i]: columns[i+1] for i in range(len(headers))}
                disk_info.append(disk_data)
    
    # Extract pool information
    pool_info_match = re.search(r'### Pool Usage\s*\n\|(.*?)\n\|(.*?)\n((?:\|.*\n)+)', content, re.DOTALL)
    pool_info = []
    
    if pool_info_match:
        headers = [h.strip() for h in pool_info_match.group(1).split('|')]
        rows = pool_info_match.group(3).strip().split('\n')
        
        for row in rows:
            columns = [col.strip() for col in row.split('|')]
            if len(columns) > len(headers):
                pool_data = {headers[i]: columns[i+1] for i in range(len(headers))}
                pool_info.append(pool_data)
    
    # Extract system storage information
    storage_info_match = re.search(r'### All Block Devices\s*```\s*(.*?)\s*```', content, re.DOTALL)
    storage_info = storage_info_match.group(1) if storage_info_match else "Not available"
    
    # Extract LVM configuration
    lvm_info_match = re.search(r'### LVM Configuration\s*```\s*(.*?)\s*```', content, re.DOTALL)
    lvm_info = lvm_info_match.group(1) if lvm_info_match else "Not available"
    
    return {
        'server_name': server_name,
        'status': status,
        'health': health,
        'version': version,
        'osd_tree': osd_tree,
        'local_osds': local_osds,
        'osd_mapping': osd_mapping,
        'osd_metadata': osd_metadata,
        'disk_info': disk_info,
        'pool_info': pool_info,
        'storage_info': storage_info,
        'lvm_info': lvm_info
    }

def parse_osd_by_server_and_type(output_files):
    """
    Parse OSD information from markdown files and organize by server and device type
    """
    servers_data = {}
    
    for file_path in output_files:
        try:
            with open(file_path, 'r') as f:
                content = f.read()
            
            # Extract server name from filename
            server_name = os.path.basename(file_path).replace('ceph-details-output-', '').replace('.md', '')
            
            # Initialize server data structure
            if server_name not in servers_data:
                servers_data[server_name] = {
                    'hdd_osds': [],
                    'ssd_osds': [],
                    'unknown_osds': []
                }
                
            # Parse detailed disk information section
            disk_info_section = re.search(r'### Detailed Disk Information\s*\n\s*\n\|\s*OSD ID.*\n\|[-:|\s]*\n((?:\|.*\n)+)', content)
            
            if disk_info_section:
                table_rows = disk_info_section.group(1).strip().split('\n')
                
                for row in table_rows:
                    # Skip empty rows
                    if not row or row.count('|') < 5:
                        continue
                    
                    # Split the row into columns
                    columns = [col.strip() for col in row.split('|')]
                    if len(columns) < 9:
                        continue
                    
                    osd_id = columns[1]
                    device_path = columns[2]
                    device_type = columns[3].lower()
                    size = columns[4]
                    model = columns[5]
                    db_device = columns[6]
                    db_size = columns[7]
                    wal_device = columns[8]
                    wal_size = columns[9] if len(columns) > 9 else "N/A"
                    
                    osd_data = {
                        'osd_id': osd_id,
                        'device_path': device_path,
                        'size': size,
                        'model': model,
                        'db_device': db_device,
                        'db_size': db_size,
                        'wal_device': wal_device,
                        'wal_size': wal_size
                    }
                    
                    # Add to appropriate category based on device type
                    if 'hdd' in device_type:
                        servers_data[server_name]['hdd_osds'].append(osd_data)
                    elif 'ssd' in device_type:
                        servers_data[server_name]['ssd_osds'].append(osd_data)
                    else:
                        servers_data[server_name]['unknown_osds'].append(osd_data)
                        
        except Exception as e:
            print(f"Error parsing {file_path}: {str(e)}")
            
    return servers_data

@app.route('/')
def index():
    output_files = find_output_files()
    
    # Process each file
    all_data = []
    for file_path in output_files:
        parsed_data = parse_output_file(file_path)
        all_data.append(parsed_data)
    
    # Render the template with the data
    return render_template('index.html', 
                          all_data=all_data, 
                          dashboard_links=[
                              {'name': 'Home', 'url': '/'},
                              {'name': 'OSDs by Server & Type', 'url': '/osds-by-server'}
                          ])

@app.route('/osds-by-server')
def osds_by_server():
    output_files = find_output_files()
    servers_data = parse_osd_by_server_and_type(output_files)
    return render_template('osds_by_server.html', servers_data=servers_data)

@app.route('/api/servers')
def api_servers():
    """API endpoint to get data for all servers."""
    output_files = find_output_files()
    
    # Process each file
    all_data = []
    for file_path in output_files:
        parsed_data = parse_output_file(file_path)
        all_data.append(parsed_data)
    
    return jsonify(all_data)

@app.route('/api/server/<server_name>')
def api_server(server_name):
    """API endpoint to get data for a specific server."""
    output_files = find_output_files()
    
    # Find the file for the specified server
    server_file = None
    for file_path in output_files:
        if server_name in file_path:
            server_file = file_path
            break
    
    if server_file:
        parsed_data = parse_output_file(server_file)
        return jsonify(parsed_data)
    else:
        return jsonify({'error': 'Server not found'})

if __name__ == '__main__':
    print(f"Starting Ceph Dashboard on port {APP_PORT}")
    app.run(debug=APP_DEBUG, host=APP_HOST, port=APP_PORT)