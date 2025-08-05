
✅ That's it! Your unified shared folder at `/var/log/timble` is now active. Any file you create, edit, or delete in this folder on one machine will appear almost instantly on the other.

## 📖 Command Reference

The script is controlled via command-line arguments. The system flags (`--system1`, `--system2`) should be the first argument.

`Usage: ./nfs-sync.sh [--system1|--system2] {command}`

| Command      | Description                                                                                  |
| :----------- | :------------------------------------------------------------------------------------------- |
| `install`    | Installs required packages (NFS, inotify-tools).                                             |
| `setup`      | Configures the NFS server/client, creates mounts, and sets up the unified folder.            |
| `start-sync` | Starts the background daemon that monitors and syncs files in real-time.                     |
| `stop-sync`  | Stops the background sync daemon.                                                            |
| `status`     | Displays a detailed status report of mounts, services, processes, and directory contents.    |
| `test`       | Performs a quick test by creating a file locally and checking if it syncs.                   |
| `cleanup`    | **(Destructive)** Stops the sync and removes all configuration (unmounts folders, cleans fstab). |
| `diagnose`   | Runs a diagnostic check for network connectivity, required packages, and services.           |

## 🔍 Troubleshooting

If you encounter issues, follow these steps:

1.  **Run the Diagnoser:** This is the best first step. It checks for common issues like network problems or missing packages.
    ```sh
    sudo ./nfs-sync.sh diagnose
    ```
2.  **Check the Status:** The `status` command gives a comprehensive overview of the current state. Look for `STOPPED` services or failed mounts.
    ```sh
    sudo ./nfs-sync.sh status
    ```
3.  **Inspect the Log File:** The script logs all actions and errors to `/var/log/nfs-realtime-sync.log`. This is the best place to find detailed error messages.
    ```sh
    tail -f /var/log/nfs-realtime-sync.log
    ```
4.  **Check the Firewall:** The script **does not** configure firewalls. NFS requires certain ports to be open. If you have a firewall enabled (`firewalld` or `ufw`), you must manually add rules.

    **For `ufw` (Debian/Ubuntu):**
    ```sh
    # On both systems, allow traffic from the other system
    sudo ufw allow from <IP_of_other_system> to any app NFS
    ```

    **For `firewalld` (CentOS/RHEL/Fedora):**
    ```sh
    # On both systems
    sudo firewall-cmd --add-service=nfs --permanent
    sudo firewall-cmd --add-service=mountd --permanent
    sudo firewall-cmd --add-service=rpc-bind --permanent
    sudo firewall-cmd --reload
    ```

## ⚠️ Important Considerations

-   **Conflict Resolution:** This script does **not** handle file conflicts. If the same file is modified simultaneously on both systems, the **last change to be written will overwrite the other**. It is not a replacement for a distributed file system like GlusterFS or a version control system like Git.
-   **Security:** The NFS export is configured with `no_root_squash`. This is often required for services running as root, but it has security implications, as the root user on the client machine will have root-level access to the exported files. Be aware of this in a production environment.
-   **Performance:** For a very high volume of small file changes, this `inotify` -> `cp`/`rm` approach may introduce I/O overhead. It is best suited for scenarios without thousands of file changes per second.

## 📜 License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
