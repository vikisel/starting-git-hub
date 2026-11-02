1. create an empty git repo on GitHub
2. open the terminal or GitBash on your PC
## Check git installation and configuration
3. git --version
4. if no git installation is found,
	a. follow instructions on this link for your operating system:
 https://git-scm.com/install/
	b. Default editor: Choose Visual Studio Code if installed; otherwise, leave the default.
	c. Initial branch name: Select Override the default branch name for new repositories and enter main.
	d. Type git --version on GitBash or terminal to confirm
5. Check if the initial branch name type on GitBash or terminal, check
		git config --global --get init.defaultBranch
		git config --global init.defaultBranch main
## Check authentication
6. Check which credential configurations exist for git
		git config --global --get-regexp "^credential\."
7. if you see lines with github.com.helper or gist.github.helper, go to 8
   if you see credential.helper manager, go to 15
   if you see nothing, go to 8 (GitHub CLI) or 15 (Git Credential Manager)
### GitHub CLI
8. check if local GitHub CLI is installed
		gh --version
9. if not installed, enter this on the terminal
		winget install --id GitHub.cli -e
   exit the terminal and/or GitBash, and reopen it/them
   if installed, check authentication status:
		gh auth status
10. if not authenticated:
		gh auth login
   and then select the following options when prompted:
	1. Where do you use GitHub? → GitHub.com
	2. Preferred protocol for Git operations? → HTTPS
	3. Authenticate Git with your GitHub credentials? → Yes
	4. How would you like to authenticate? → Login with a web browser
11. verify authentication with
		gh auth status
12. ensure Git uses the authenticated credentials
		gh auth setup-git
13. verify
		gh api user --jq .login
14. go to step xx
[
git config --global --unset-all credential.https://github.com.helper
]
### Using git credential manager (GCM)
15. ensure GCM is installed
		git credential-manager --version
	go to 14
16. a. if not, install with
		winget install --id Microsoft.GitCredentialManager -e
    b. configure
		git credential-manager configure
	c. verify
		git credential-manager --version
	d. go to 14
17. check credential managers available on the system for git
		git config --show-origin --get-all credential.helper
	[
	decide the ones you want to keep/remove
	to remove including all system configs:
		start terminal as administrator
		git config --system --unset-all credential.helper
	to remove global credentials except the system level config
		continue on the same terminal
		git config --global --unset-all credential.helper
		]
18. if one exists for git:
Check if any user is authenticated and which ones
git credential-manager github list
	1. if empty or non-empty without your username, go to 17
	2. if your user name is there, go to 18
19. If no GCM exists, configure one
git config --global --add credential.helper "manager" 
20. configure the user name (whatever you prefer) and e-mail (github no-reply email) to set the fields that will be visible when you commit 
git config --global user.name "YourUsername"
git config --global user.email "sometext@users.noreply.github.com"
21. initiate GitHub authentication
git credential-manager github login
	1. How would you like to authenticate? → Login with a web browser
22. Verify authentication again
git credential-manager github list
23. verify access to the GitHub repo
git ls-remote https://github.com/UserName/RepoName.git
[
remove credentials
git config --global --unset-all credential.helper
]
## initialize repo:
24. navigate to the local folder you want to add to this repo in the terminal window 
git init
git branch -M main
git add .
git commit -m "Initial commit"
git remote add origin https://github.com/YOUR_USERNAME/REPO_NAME.git
git push -u origin main