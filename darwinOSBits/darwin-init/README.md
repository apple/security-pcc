Copyright © 2026 Apple Inc. All Rights Reserved.

APPLE INC.
PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT
PLEASE READ THE FOLLOWING PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT (“AGREEMENT”) CAREFULLY BEFORE DOWNLOADING OR USING THE APPLE SOFTWARE ACCOMPANYING THIS AGREEMENT(AS DEFINED BELOW). BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING TO BE BOUND BY THE TERMS OF THIS AGREEMENT. IF YOU DO NOT AGREE TO THE TERMS OF THIS AGREEMENT, DO NOT DOWNLOAD OR USE THE APPLE SOFTWARE. THESE TERMS AND CONDITIONS CONSTITUTE A LEGAL AGREEMENT BETWEEN YOU AND APPLE.
IMPORTANT NOTE: BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING ON YOUR OWN BEHALF AND/OR ON BEHALF OF YOUR COMPANY OR ORGANIZATION TO THE TERMS OF THIS AGREEMENT.
1. As used in this Agreement, the term “Apple Software” collectively means and includes all of the Apple Private Cloud Compute materials provided by Apple here, including but not limited to the Apple Private Cloud Compute software, tools, data, files, frameworks, libraries, documentation, logs and other Apple-created materials. In consideration for your agreement to abide by the following terms, conditioned upon your compliance with these terms and subject to these terms, Apple grants you, for a period of ninety (90) days from the date you download the Apple Software, a limited, non-exclusive, non-sublicensable license under Apple’s copyrights in the Apple Software to download, install, compile and run the Apple Software internally within your organization only on a single Apple-branded computer you own or control, for the sole purpose of verifying the security and privacy characteristics of Apple Private Cloud Compute. This Agreement does not allow the Apple Software to exist on more than one Apple-branded computer at a time, and you may not distribute or make the Apple Software available over a network where it could be used by multiple devices at the same time. You may not, directly or indirectly, redistribute the Apple Software or any portions thereof. The Apple Software is only licensed and intended for use as expressly stated above and may not be used for other purposes or in other contexts without Apple's prior written permission. Except as expressly stated in this notice, no other rights or licenses, express or implied, are granted by Apple herein.
2. The Apple Software is provided by Apple on an "AS IS" basis. APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS, SYSTEMS, OR SERVICES. APPLE DOES NOT WARRANT THAT THE APPLE SOFTWARE WILL MEET YOUR REQUIREMENTS, THAT THE OPERATION OF THE APPLE SOFTWARE WILL BE UNINTERRUPTED OR ERROR-FREE, THAT DEFECTS IN THE APPLE SOFTWARE WILL BE CORRECTED, OR THAT THE APPLE SOFTWARE WILL BE COMPATIBLE WITH FUTURE APPLE PRODUCTS, SOFTWARE OR SERVICES. NO ORAL OR WRITTEN INFORMATION OR ADVICE GIVEN BY APPLE OR AN APPLE AUTHORIZED REPRESENTATIVE WILL CREATE A WARRANTY.
3. IN NO EVENT SHALL APPLE BE LIABLE FOR ANY DIRECT, SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, COMPILATION OR OPERATION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
4. This Agreement is effective until terminated. Your rights under this Agreement will terminate automatically without notice from Apple if you fail to comply with any term(s) of this Agreement. Upon termination, you agree to cease all use of the Apple Software and destroy all copies, full or partial, of the Apple Software. This Agreement constitutes the entire understanding of the parties with respect to the subject matter contained herein, and supersedes all prior negotiations, representations, or understandings, written or oral. This Agreement will be governed and construed in accordance with the laws of the State of California, without regard to its choice of law rules.
You may report security issues about Apple products to product-security@apple.com, as described here: https://www.apple.com/support/security/. Non-security bugs and enhancement requests can be made via https://bugreport.apple.com as described here: https://developer.apple.com/bug-reporting/
EA1937
10/02/2024

#  `darwin-init`

`darwin-init` is a standard part of DarwinOS that can be used to configure a standard B&I build of DarwinOS for specific users and applications. Darwin-init is a daemon that executes at the first boot and is configured via nvram parameters. This is intended to be useful for both configuring DarwinOS in virtual machines as well as configuring DarwinOS on bare metal. Each of the following items can be configured, all are optional:

 * sending messages to the log, 
 * setting the computer name, 
 * adding a user, 
 * install a root, 
 * running  commands, and
 * reboot the machine. 

The workflow to configure a machine generally follows the following steps.

1. (Optional) Creation of a single unified root that contains the difference between the base DarwinOS system and the system that you are setting up. This is different than the typical Linux systems where packages are individually brought to a machine. This root can contain new daemons, launchctl plists, applications, frameworks, etc. The root can contain a scripts that can be executed to configure what is unique about a particular machine. If the root contains changes to the kernel or other changes that require a reboot, the machine can be rebooted. The expectation is that after the root is installed and potentially rebooted, the system will function as expected. If this is not possible to do in one step, it is possible for this step to download chef or puppet to complete the installation. This root can be read from a mounted volume to a virtual machine or read over the network from a URL. It is also possible for the server that is providing the root to customize the file when the URL is requested. 

2. Creation of a json parameter that is used to tell darwin-init what to do. This configuration file is created by the `darwin-init generate` subcommand. 

3. Passing the configuration file to the new DarwinOS installation as a base64 encoded nvram parameter `darwin-init=`. 

4. Boot the machine and if the `darwin-init` parameter is available, it will be processed. 

## `darwin-init help`

Briefly summarized the subcommands. These include: 

    %  darwin-init
    USAGE:

        darwin-init <SUBCOMMAND>

    DESCRIPTION:

        The darwin-init command enables the creation and implementation of
        configuration parameters that will be applied by DarwinOS at the first boot.
        The subcommand "generate" creates a json file, the subcommand "print" prints
        the file and the subcommand "apply" is used by DarwinOS when DarwinOS boots
        for the first time.

    REQUIRED:

        SUBCOMMAND                  The subcommand to invoke

    SUBCOMMANDS:

        generate                    Generates a new configuration
        apply                       The subcommand to apply the configuration to the
                                    running system
        print                       print the generated darwin-init json
        help                        prints helpful information

Of these commands, `apply` is an internal parameters that is used during installation and is not usable from the CLI. 

## `darwin-init generate`

The darwin generate command has the following syntax. 

# darwin-init help generate

    OVERVIEW: Generates a new configuration
    
    The generate subcommand takes various arguments and creates a json file that can be passed to the darwinOS through boot-args. This allows the command "darwin-init apply" to configure the system to these specifications.
    
    USAGE: darwin-init generate [<options>] <file-name> --ssh --perfdata --reboot --admin --passwordless-sudo
    
    ARGUMENTS:
      <file-name>             The file name to store the generated configuration
    
    OPTIONS:
      -l, --log <log>         A message to be placed in the log
      -s, --ssh/--no-ssh      Enable SSH daemon
      -P, --perfdata/--no-perfdata
                              Collect performance data at boot
      -c, --computer-name <computer-name>
                              Name to set the computer name to
      -c, --cryptex <cryptex> URL of the cryptexes to install
      -V, --cryptex-variant <cryptex-variant>
                              Variant names for the cryptexes
      --cryptex-size <cryptex-size>
                              Sizes of the compressed cryptexes
      --cryptex-sha256 <cryptex-sha256>
                              Hexadecimal sha256 digests of the compressed cryptexes
      --cryptex-authorization-service <cryptex-authorization-service>
                              Authorization services used to verify cryptex validities
      --diavlo-url <diavlo-url>
                              URL to the diavlo authorization server
      --diavlo-root-certificate <diavlo-root-certificate>
                              PEM encoded root certificate of the the diavlo authorization server
      --diavlo-sign-using-apple-connect
                              Use AppleConnect credentials to trust the diavlo authorization server
      -p, --package <package> URL of the packages to install
      -w, --wait <wait>       Causes darwin-init to delay before executing any install steps until the specified mount point has become available
      -B, --preflight <preflight>
                              Shell script that will be executed before the root is installed. The script will be executed using customizable shell and may include files found on mount points that may not be in the base install (such as sumac -v).
      -T, --preflight-shell <preflight-shell>
                              A complete path the shell that'll be used to executed preflight script. If not specified it defaults to /bin/bash. All preflights run under a shell.
      -r, --root <root>       A root that will be passed to the darwinup command. This can be a URL. If it is a URL, it causes darwin-init to wait until the destination is reachable.
      -A, --postflight <postflight>
                              Shell script that will be executed after the root is installed. The script will be executed using customizable shell. Script may include files that have been installed by the root.
      -S, --postflight-shell <postflight-shell>
                              A complete path the shell that'll be used to executed postflight script. If not specified it defaults to /bin/bash. All postflights run under a shell.
      -R, --reboot/--no-reboot
                              Reboot the machine after the preflight, root install, and postflight
      --preference <preference>
                              Preference key to update
      --preference-value <preference-value>
                              Preference value as json, use "null" to delete a preference.
      --preference-application-id <preference-application-id>
                              Restrict preference domain by applicationId (default: kCFPreferencesAnyApplication)
      --preference-username <preference-username>
                              Restrict preference domain by user (default: kCFPreferencesAnyUser)
      --preference-hostname <preference-hostname>
                              Restrict preference domain by host (default: kCFPreferencesCurrentHost)
      -u, --user <user>       Specifies the "username,uid,gid" of a user
      -p, --password <password>
                              Specifies the password of the user
      -a, --admin/--no-admin  Specifies that the user should have admin privileges
      -p, --passwordless-sudo/--no-passwordless-sudo
                              Enable users of the admin group to be perform sudo operations without prompting for a password
      -k, --key <key>         A file pointer to the ssh authorized_keys file containing at least one public key
      -h, --help              Show help information.

### MacOS Example 

The following command create a json file for creating a user, installing a root and running a couple of commands that are available through a volume provided by hypervisor. 

    % darwin-init generate \
        --log='Configuring machine asdf.local' \
        --computerName=asdf.local \
        --user='asdf,501,501' \
        --admin \
        --key='.ssh/id_ecdsa.pub' \
        --ssh \
        --wait \
        --preflight='/Volume/foo bar.sh before' \
        --root='/Volume/foo/root.tgz' \
        --postflight='/Volume/foo/bar.sh after' \
        macOS.json

The resulting json (sent through `json_pp`):

    % json_pp < macOS.json 
    {
       "logtext" : "Configuring machine asdf.local",
       "compname" : "asdf.local",
       "install" : {
          "root" : "/Volume/foo/root.tgz",
          "postflight" : "/Volume/foo/bar.sh after",
          "waitForVolume" : "--preflight=/Volume/foo bar.sh before",
          "reboot" : "NO"
       },
       "user" : {
          "ssh_authorized_key" : "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBKK+CkQ6PFb4dgDDJIoOGV+dVutR2J7zU9/Oqg7EGFk+QuIB97ubImfchCUAHMkxCsI+ws7cu7uX7wHzsXpPALo= hughes@Jamess-MacBook-Pro.local\n",
          "gid" : "501",
          "uid" : "501",
          "name" : "asdf",
          "isAdmin" : "YES"
          "ssh" : "YES"
       }
    }

### iOS Example

The iOS example does not set a user or execute a preflight but does get a root from the network. 

    % darwin-init generate \
        --log='Configuring machine xyzzy.local' \
        --computerName=xyzzy.local \
        --root='https://host.apple.com/path/to/file.tgz' \
        --postflight='/usr/local/foo/bar.sh after' \
        --reboot \
        iOS.json

## `darwin-init print`

A simple program that validates the json. Can be used with custom written json that was not generated by `darwin-init generate`. 

### Example 

Printing the macOS.json from above.

    % darwin-init print macOS.json
    Successfully parsed config from macOS.json
    Log Message: Configuring machine asdf.local
    NewUser
        User: asdf
        Password: (null)
        UID: 501
        GID: 501
        key: ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBKK+CkQ6PFb4dgDDJIoOGV+dVutR2J7zU9/Oqg7EGFk+QuIB97ubImfchCUAHMkxCsI+ws7cu7uX7wHzsXpPALo= hughes@Jamess-MacBook-Pro.local
        New user is admin
        Start ssh daemon
    Install
        Preflight: (null)
        Root: /Volume/foo/root.tgz
        Postflight: /Volume/foo/bar.sh after
        reboot: False
    Computer Name: asdf.local

