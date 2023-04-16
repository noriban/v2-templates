terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
    }
    docker = {
      source  = "kreuzwerker/docker"
    }
  }
}

data "coder_workspace" "me" {
}

provider "docker" {

}

provider "coder" {
  feature_use_managed_variables = "true"
}

data "coder_parameter" "shell" {
  name        = "Unix shell"
  type        = "string"
  description = "What command-line interpreter or shell do you want?"
  mutable     = true
  default     = "bash"
  icon        = "https://cdn3.iconfinder.com/data/icons/blue-ulitto/128/Developer_files_Bash_Shell_Script-512.png"

  option {
    name = "bash"
    value = "bash"
    icon = "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a3/Bash_Logo_White.svg/1200px-Bash_Logo_White.svg.png"
  }
  option {
    name = "zsh"
    value = "zsh"
    icon = "https://upload.wikimedia.org/wikipedia/commons/1/1e/Oh_My_Zsh_logo.png"
  }
  option {
    name = "fish"
    value = "fish"
    icon = "https://fishshell.com/assets/img/Terminal_Logo2_CRT_Flat.png"
  }       
}

data "coder_parameter" "cpu" {
  name        = "CPU Share"
  type        = "number"
  description = "What Docker CPU share do you want? (e.g., 1 physical CPU available, and 512 equates to 50% of the CPU)"
  mutable     = true
  default     = 1024
  icon        = "https://png.pngtree.com/png-clipart/20191122/original/pngtree-processor-icon-png-image_5165793.jpg"

  validation {
    min       = 512
    max       = 4096
  }

}

data "coder_parameter" "memory" {
  name        = "Memory"
  type        = "number"
  description = "What Docker memory do you want?"
  mutable     = true
  default     = 1024
  icon        = "https://www.vhv.rs/dpng/d/33-338595_random-access-memory-logo-hd-png-download.png"

  validation {
    min       = 512
    max       = 4096
  }

}

#data "coder_parameter" "disk_size" {
#  name        = "Disk"
#  type        = "number"
#  description = "What Docker CPU share do you want?"
#  mutable     = true
#  default     = 10
#  icon        = "https://www.pngall.com/wp-content/uploads/5/Database-Storage-PNG-Clipart.png"
#
#  validation {
#    min       = 10
#    max       = 15
#  }
#
#}


resource "coder_agent" "dev" {
  arch           = "amd64"
  os             = "linux"

  metadata {
    display_name = "CPU Usage"
    key  = "cpu"
    # calculates CPU usage by summing the "us", "sy" and "id" columns of
    # vmstat.
    script = <<EOT
        top -bn1 | awk 'FNR==3 {printf "%2.0f%%", $2+$3+$4}'
        #vmstat | awk 'FNR==3 {printf "%2.0f%%", $13+$14+$16}'
    EOT
    interval = 1
    timeout = 1
  }

  metadata {
    display_name = "Disk Usage"
    key  = "disk"
    script = "df -h | awk '$6 ~ /^\\/$/ { print $5 }'"
    interval = 1
    timeout = 1
  }

  metadata {
    display_name = "Memory Usage"
    key  = "mem"
    script = <<EOT
    free | awk '/^Mem/ { printf("%.0f%%", $3/$2 * 100.0) }'
    EOT
    interval = 1
    timeout = 1
  }

  metadata {
    display_name = "Load Average"
    key  = "load"
    script = <<EOT
        awk '{print $1,$2,$3,$4}' /proc/loadavg
    EOT
    interval = 1
    timeout = 1
  }

  metadata {
    display_name = "@CoderHQ Weather"
    key  = "weather"
    # for more info: https://github.com/chubin/wttr.in
    script = <<EOT
        curl -s 'wttr.in/{Austin}?format=3&u' 2>&1 | awk '{print}'
    EOT
    interval = 600
    timeout = 10
  }

  env = { "SHELL_TYPE" = data.coder_parameter.shell.value }


  startup_script  = <<EOT
#!/bin/bash

# copy dotfiles
if [ "$SHELL_TYPE" == "bash" ]; then
  cp /coder/.bashrc $HOME/.bashrc
elif [ "$SHELL_TYPE" == "zsh" ]; then
  cp /coder/.zshrc $HOME/.zshrc
elif [ "$SHELL_TYPE" == "fish" ]; then
  cp /coder/config.fish $HOME/.config/fish/config.fish
else
  echo "no unix shell dotfiles copied"
fi

# install code-server
curl -fsSL https://code-server.dev/install.sh | sh
code-server --auth none --port 13337 &

# change shell
# .zshenv, .zprofile, .zshrc, .zlogin
sudo chsh -s $(which $SHELL_TYPE) $(whoami)

  EOT  
}

resource "coder_app" "code-server" {
  agent_id = coder_agent.dev.id
  slug          = "code-server"  
  display_name  = "VS Code Web"
  url      = "http://localhost:13337/?folder=/home/coder"
  icon     = "/icon/code.svg"
  subdomain = false
  share     = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 5
    threshold = 15
  }  
}

resource "docker_image" image {
  name = "marktmilligan/base-shells:latest"
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  image = docker_image.image.name
  # Uses lower() to avoid Docker restriction on container names.
  name     = "coder-${data.coder_workspace.me.owner}-${lower(data.coder_workspace.me.name)}"
  hostname = lower(data.coder_workspace.me.name)
  dns      = ["1.1.1.1"]

  # CPU usage
  cpu_shares = data.coder_parameter.cpu.value

  # GB memory
  memory = data.coder_parameter.memory.value

  # overlayfs (root filesystem)
  #storage_opts = {
  #  size = "${data.coder_parameter.disk_size.value}G"
  #}

  # Use the docker gateway if the access URL is 127.0.0.1
  #entrypoint = ["sh", "-c", replace(coder_agent.dev.init_script, "127.0.0.1", "host.docker.internal")]

  # Use the docker gateway if the access URL is 127.0.0.1
  command = [
    "sh", "-c",
    <<EOT
    trap '[ $? -ne 0 ] && echo === Agent script exited with non-zero code. Sleeping infinitely to preserve logs... && sleep infinity' EXIT
    ${replace(coder_agent.dev.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")}
    EOT
  ]


  env        = ["CODER_AGENT_TOKEN=${coder_agent.dev.token}"]
  volumes {
    container_path = "/home/coder/"
    volume_name    = docker_volume.coder_volume.name
    read_only      = false
  }  
  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }
}

resource "docker_volume" "coder_volume" {
  name = "coder-${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}"
}
