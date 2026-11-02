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
		
## Check user configuration
6. check username and e-mail addresses for git
		git config --global --get user.name
	if not you github username (any other username is fine, but it is easier to ensure it is you)
		git config --global user.name "YourGitHubUsername"
	check e-mail address for git	
		git config --global --get user.e-mail
	if not user no-reply GitHub e-mail, change
		git config --global user.email "sometext@users.noreply.github.com"
		
## Check authentication
7. Check which credential configurations exist for git
		git config --show-origin --get-regexp "^credential\."
8. if you see lines with github.com.helper or gist.github.helper with existing values, go to 9
   if you see credential.helper manager, go to 14
   if you see nothing, go to 9 (GitHub CLI) or 14 (Git Credential Manager)
### GitHub CLI
9. verify installation for GitHub CLI
		gh --version
   if empty, install and restart the terminal and/or GitBash
		winget install --id GitHub.cli -e
10. check authentication status:
		gh auth status
11. if you need to authenticate:
		gh auth login
   and then select the following options when prompted:
	1. Where do you use GitHub? → GitHub.com
	2. Preferred protocol for Git operations? → HTTPS
	3. Authenticate Git with your GitHub credentials? → Yes
	4. How would you like to authenticate? → Login with a web browser
12. verify authentication with
		gh auth status
13. ensure Git uses the authenticated credentials
		gh auth setup-git
14. go to 19

### Git credential manager (GCM)
15. check if GCM is installed
		git credential-manager --version
	if ok, go to 16
	if not, install with
		winget install --id Microsoft.GitCredentialManager -e
	go to 16	
16. check GCM is configured for GitHub
		git config --get-urlmatch credential https://github.com		if empty  go to 16
	if not, configure at the user level
		git config --global --add credential.helper "manager"	
17. check GitHub accounts known to GCM
		git credential-manager github list
18. authenticate if the user is missing 	
		git credential-manager github login
	1. How would you like to authenticate? → Login with a web browser
	complete steps & verify authentication
		git credential-manager github list
	go to 19
	
## Initialize repo
19. verify read access to the GitHub repo
		git ls-remote https://github.com/UserName/RepoName.git
	alternatively, using GitHub CLIgh 
		repo view https://github.com/UserName/RepoName.git --json viewerPermission
20. navigate to the local folder you want to add to this repo in the terminal window 
		cd "C:\Users\USERNAME\Documents\MyProject"
	check whether it is already a git folder
		git rev-parse --is-inside-work-tree
	if not
		git init
		git status
		git branch -M main
	check branch
		git branch --show-current
	Stage files, commit with a message & push
		git add .
		git status
		git commit -m "Initial commit"
		git remote add origin https://github.com/YOUR_USERNAME/REPONAME.git
		git push -u origin main
