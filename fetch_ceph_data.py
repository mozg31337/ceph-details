#!/usr/bin/env python3
"""
Script to run get_ceph_info.sh on remote servers via SSH,
wait for completion, and download the generated output files
to the local output directory.
"""

import os
import sys
import paramiko
import configparser
import getpass
from pathlib import Path
import time

def read_config(config_path):
    """Read configuration file and return config object."""
    if not os.path.exists(config_path):
        print(f"Error: Config file {config_path} not found.")
        sys.exit(1)
    
    config = configparser.ConfigParser()
    config.read(config_path)
    
    return config

def validate_config(config):
    """Validate that the config file has required sections and options."""
    required_sections = ['ssh', 'servers', 'paths']
    required_ssh_options = ['username', 'key_file']
    required_paths_options = ['remote_script_path']
    
    for section in required_sections:
        if section not in config:
            print(f"Error: Required section '{section}' missing from config file.")
            sys.exit(1)
    
    for option in required_ssh_options:
        if option not in config['ssh']:
            print(f"Error: Required option '{option}' missing from [ssh] section.")
            sys.exit(1)
            
    for option in required_paths_options:
        if option not in config['paths']:
            print(f"Error: Required option '{option}' missing from [paths] section.")
            sys.exit(1)
    
    if not config['servers']:
        print(f"Error: No servers specified in the [servers] section.")
        sys.exit(1)

def execute_remote_script_and_fetch_output(config):
    """
    Connect to each server, run the get_ceph_info.sh script,
    wait for completion, then download the generated output file.
    """
    # Create output directory if it doesn't exist
    output_dir = Path('output')
    output_dir.mkdir(exist_ok=True)
    
    # Get SSH connection details
    username = config['ssh']['username']
    key_file = os.path.expanduser(config['ssh']['key_file'])
    remote_script_path = config['paths']['remote_script_path']
    
    # Check if key file exists
    if not os.path.exists(key_file):
        print(f"Error: SSH key file {key_file} not found.")
        sys.exit(1)
    
    # Get key password ONCE if needed
    key_password = None
    if 'key_requires_password' in config['ssh'] and config['ssh'].getboolean('key_requires_password'):
        key_password = getpass.getpass(f"Enter password for SSH key {key_file}: ")
    
    # Get sudo password ONCE (will be needed for running the script with sudo)
    sudo_password = getpass.getpass("Enter sudo password for remote servers: ")
    
    # Setup SSH client
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    
    servers_successful = 0
    servers_failed = 0
    
    # Connect to each server, run the script, and download the output file
    for server_name, server_ip in config['servers'].items():
        try:
            print(f"Connecting to {server_name} ({server_ip})...")
            
            # Load private key - determine key type and use appropriate loader
            try:
                # Try to load the key and determine its type automatically
                private_key = paramiko.Ed25519Key.from_private_key_file(key_file, password=key_password)
            except paramiko.ssh_exception.SSHException:
                try:
                    private_key = paramiko.RSAKey.from_private_key_file(key_file, password=key_password)
                except paramiko.ssh_exception.SSHException:
                    try:
                        private_key = paramiko.ECDSAKey.from_private_key_file(key_file, password=key_password)
                    except paramiko.ssh_exception.SSHException:
                        try:
                            private_key = paramiko.DSSKey.from_private_key_file(key_file, password=key_password)
                        except paramiko.ssh_exception.SSHException:
                            print(f"Error: Unable to determine the type of the SSH key {key_file} or key is invalid.")
                            sys.exit(1)
                        
            try:
                ssh.connect(server_ip, username=username, pkey=private_key)
            except paramiko.ssh_exception.PasswordRequiredException:
                print(f"Error: SSH key requires a password. Please set key_requires_password=true in config.")
                sys.exit(1)
            except Exception as e:
                print(f"Error connecting to {server_name} ({server_ip}): {str(e)}")
                servers_failed += 1
                continue
            
            # Get an interactive session for handling sudo
            channel = ssh.invoke_shell()
            
            # Set terminal dimensions to avoid wrapping issues
            channel.resize_pty(width=200, height=50)
            
            # Wait for initial prompt
            output = b''
            while not output.endswith(b'$ '):
                if channel.recv_ready():
                    chunk = channel.recv(1024)
                    output += chunk
                time.sleep(0.1)
            
            # Navigate to the directory containing the script
            script_dir = os.path.dirname(remote_script_path)
            script_name = os.path.basename(remote_script_path)
            
            if script_dir:
                channel.send(f"cd {script_dir}\n")
                # Wait for completion
                output = b''
                while not output.endswith(b'$ '):
                    if channel.recv_ready():
                        chunk = channel.recv(1024)
                        output += chunk
                    time.sleep(0.1)
            
            # Make the script executable
            channel.send(f"chmod +x {script_name}\n")
            # Wait for completion
            output = b''
            while not output.endswith(b'$ '):
                if channel.recv_ready():
                    chunk = channel.recv(1024)
                    output += chunk
                time.sleep(0.1)
            
            # Run the script with sudo
            print(f"Running get_ceph_info.sh on {server_name} with sudo (this may take several minutes)...")
            channel.send(f"sudo ./{script_name}\n")
            
            # Handle sudo password prompt
            output = b''
            sudo_prompted = False
            script_completed = False
            
            # Wait for sudo password prompt or completion
            while not script_completed:
                if channel.recv_ready():
                    chunk = channel.recv(1024)
                    output += chunk
                    
                    # Check for sudo password prompt
                    if b'password for' in output.lower() and not sudo_prompted:
                        channel.send(sudo_password + '\n')
                        sudo_prompted = True
                    
                    # Check if script has completed
                    if b'Results saved to ceph-mapping.md' in output:
                        script_completed = True
                        print(f"Script execution completed on {server_name}")
                
                time.sleep(0.5)
            
            # Now download the output file using SFTP
            sftp = ssh.open_sftp()
            
            # Determine the path of the output file
            if script_dir:
                remote_output_path = f"{script_dir}/ceph-mapping.md"
            else:
                remote_output_path = "./ceph-mapping.md"
                
            local_file = output_dir / f"ceph-details-output-{server_name}.md"
            
            try:
                # Give the file system a moment to finish writing
                time.sleep(1)
                print(f"Downloading output file to {local_file}...")
                sftp.get(remote_output_path, local_file)
                print(f"Download complete!")
                servers_successful += 1
            except FileNotFoundError:
                print(f"Error: Output file not found on {server_name}. Check if the script generated ceph-mapping.md.")
                servers_failed += 1
            except Exception as e:
                print(f"Error downloading output file from {server_name}: {str(e)}")
                servers_failed += 1
            
            # Close connections
            channel.close()
            sftp.close()
            ssh.close()
            
        except Exception as e:
            print(f"Unexpected error with {server_name}: {str(e)}")
            servers_failed += 1
            try:
                ssh.close()
            except:
                pass
    
    # Securely delete password variables from memory
    del sudo_password
    if key_password:
        del key_password
    
    # Print summary
    print(f"\nSummary: Successfully processed {servers_successful} servers, failed for {servers_failed} servers.")
    if servers_successful > 0:
        print(f"Output files are available in the '{output_dir}' directory.")

def main():
    """Main function."""
    # Default config file path
    config_path = 'config.conf'
    
    # Allow overriding config path from command line
    if len(sys.argv) > 1:
        config_path = sys.argv[1]
    
    # Read and validate config
    config = read_config(config_path)
    validate_config(config)
    
    # Execute remote script and fetch output
    execute_remote_script_and_fetch_output(config)

if __name__ == '__main__':
    main()