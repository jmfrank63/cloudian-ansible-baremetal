#!/bin/bash
# Copyright: (c) 2008-2017 Cloudian, Inc. All rights reserved.

shopt -s extglob
set -euo pipefail

#TODO()
	#Simple helper function to exit the script when leaving something unfinished
	#Exit Codes:	255
function TODO() {
	local -a _caller
	local -i _frame=0
	local IFS

	printf '\nTODO Exit\n'
	while [[ ${#} -gt 0 ]]; do
		printf 'Arguments: %s\n' "${1}"
		shift
	done
	printf '%s\n' 'Begin Call Trace'
	while _caller=($(caller ${_frame})); do #0: Line Number; 1: Function Name; 2: Script File Name
		(( ++_frame ));
		printf '%s\n' "	Call Trace (${_frame}): Line ${_caller[0]} in ${_caller[2]}::${_caller[1]}"
	done
	printf '%s\n' 'End Call Trace'

	exit 255
}

### Global Variables ###
### ################ ###
declare -i false=0
declare -i true=1

[[ "${DEBUG:+false}" != 'false' ]] && declare -i DEBUG=${false}
[[ "${@#*--debug}" != "${@}" ]] && DEBUG=${true}
declare -i LOG_DEBUG=${false}

#Version Details
declare -i VERSION_MAJOR=2
declare -i VERSION_MINOR=4
declare -i VERSION_RELEASE=14
declare VERSION_STATE=''
declare VERSION="${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_RELEASE}"
[[ -n "${VERSION_STATE:-}" ]] && VERSION+="-${VERSION_STATE}"

#Constants
declare -i INPUT_RETURN_STYLE_SELECTED_INDEX=0 #Return the array index for the selected value
declare -i INPUT_RETURN_STYLE_SELECTED_INPUT=1 #Return the selected input value
declare -i INPUT_RETURN_STYLE_SELECTED_VALUE=2 #Return the array value for the selected value
declare -i INPUT_RETURN_STYLE_TYPED_INPUT=3 #Return the received input

declare -a BREADCRUMBS=('System Setup') #Default title

declare -i DEFAULT_RESPONSE_AS_INPUT=${false}
	#When true, __getInput will will place DefaultResponse in text input
	#Otherwise pressing enter will set empty input to DefaultResponse
declare -i EXIT_CANCELLED=${false} #Only set true by __trapCtrlC and handled and set back to false by __getInput
declare -i FORCE_STDIN=${false} #Used by __getInput if detects input redirection with no input provided
declare -i SUPPRESS_CLEAR=${false} #If true, __clearScreen will not wipe the screen, otherwise it will
declare -i SUPPRESS_CURSOR_MOVEMENT=${false}
declare -i PRINT_MENU_COMMENTS=${false} #If true, prints menu items that begin with ##, otherwise it hides them
declare -i INPUT_RETURN_STYLE=${INPUT_RETURN_STYLE_SELECTED_INPUT} #Used by __getMenuInput and __getMultipleChoiceInput
declare -i INPUT_LIMIT=5
declare -i MAX_COLUMN_WIDTH=39
declare -i MAX_HOSTNAME_LENGTH=$(getconf HOST_NAME_MAX) #Maximum length of hostname
declare -i MAX_SINGLE_COLUMN_OPTIONS=20
declare VLAN_NAME_TYPE='RAW_PLUS_VID_NO_PAD'
declare -A VLAN_NAME_TYPES=(
	['RAW_PLUS_VID']='%s.%.4i'      #eth0.0010
	['RAW_PLUS_VID_NO_PAD']='%s.%i' #eth0.10
	['PLUS_VID']='vlan%.4i'         #vlan0010
	['PLUS_VID_NO_PAD']='vlan%i'    #vlan10
)

declare FSTAB='/etc/fstab'

declare REGEX_IPADDRESS="^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"
### ################ ###

### BEGIN: Function Declarations ###
### ############################ ###

#__addBreadcrumb(Crumb)
	#Adds Crumb to BREADCRUMBS array used by __printTitle
	#Return Codes:	0
function __addBreadcrumb() {
	#Dependencies:	__raiseError, __raiseWrongParametersError, __removeBreadcrumb
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _crumb="${1:?$(__raiseError "Crumb is required")}"

	__removeBreadcrumb "${_crumb}"
	BREADCRUMBS+=("${_crumb}")

	return 0
}

#__checkInstalledPackage(PackageName)
	#Checks to see if the specified PackageName is currently installed
	#Return Codes:  0=Installed; 1=Not Installed
	#Exit Codes:	254=Invalid Parameter Count; 255=Required parameter
function __checkInstalledPackage() {
	#Dependencies:	__raiseError, __raiseWrongParametersError
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _packageName="${1:?$(__raiseError 'PackageName is required')}"

	[[ -z "$(__trim "${_packageName}")" ]] && __raiseError 'PackageName is required'

	rpm --quiet -q "${_packageName}" && return 0 || return 1
}

#__clearScreen()
	#Clears all text from the screen when not in debug mode
	#Returns:	0
function __clearScreen() {
	#Dependencies:	__getClearScreenState, __isDebugEnabled, __printMessage, __setCursorPosition
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	if __isDebugEnabled; then
		__printMessage "${IRED}${ONBLUE}	---> Debugging Clear Screen Disabled <---${RST}"
	elif ! __getClearScreenState ${true}; then
		__printMessage "${IRED}${ONBLUE}	---> Suppressed Clear Screen <---${RST}"
	else
		__logMessage 'Cleared Screen'
		__setCursorPosition 0 0 ${true} #Move to cursor position 0 0 (top left)
	fi

	return 0
}

#__createDirectory(DirectoryName)
	#Creates DirectoryName if it does not exist
	#Return Codes:	0=Success; 1=Failed
function __createDirectory() {
	#Dependencies:	__printMessage, __raiseError, __raiseWrongParametersError
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _directoryName="${1:?$(__raiseError 'DirectoryName is required')}"

	__printMessage "Creating Directory '${IWHITE}${_directoryName}${RST}' ... " ${false}
	if [[ -d "${_directoryName}" ]]; then
		__printMessage "${IYELLOW}Already Exists"
	elif mkdir -p "${_directoryName}"; then
		__printMessage "${IGREEN}Done"
	else
		__printMessage "${IRED}Failed"
		return 1
	fi

	return 0
}

#__createFile(FileName)
	#Creates FileName if doesn't already Exist
	#Return Codes:	0=Success; 1=Failed to create FileName; 2=Failed to create directory path
function __createFile() {
	#Dependencies:	__printMessage, __raiseError, __raiseWrongParametersError
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _fileName="${1:?$(__raiseError 'FileName is required')}"

	if [[ ! -d "$(__getDirectoryName "${_fileName}")" ]]; then
		__createDirectory "$(__getDirectoryName "${_fileName}")" || return 2
	fi

	__printMessage "Creating File '${IWHITE}${_fileName}${RST}' ... " ${false}
	if [[ -f "${_fileName}" ]]; then
		__printMessage "${IYELLOW}Already Exists"
	elif touch "${_fileName}"; then
		__printMessage "${IGREEN}Done"
	else
		__printMessage "${IRED}Failed"
		return 1
	fi

	return 0
}

#__disableAutoLogin()
	#Return Codes:	0=Success
function __disableAutoLogin() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	__removeFile '/etc/init/tty.override' || return ${?}

	return 0
}

#__downloadURI(URL, SaveFile, DisplayName="")
	#Downloads the specified URL and saves the output to SaveFile
	#Returns:	0=Success; 1=Failed to download
function __downloadURI() {
	#Dependencies:	__getCursorPosition, __printMessage, __printStatusMessage, __raiseError, __raiseWrongParametersError
	[[ ${#} -lt 2 || ${#} -gt 5 ]] && __raiseWrongParametersError ${#} 2 5
	local _displayName="${3:-}"
	local _displayURL
	local _permissions
	local -a _position
	local _saveFile="${2:?$(__raiseError 'SaveFile is required')}"
	local _url="${1:?$(__raiseError 'URL is required')}"

	_displayURL="${_url%%\?*}"
	_displayURL="${_displayURL%%/dl/*}"
	_displayURL="${_displayURL##ftp\:\/\/*@}"

	if [[ -n "${_displayName}" ]]; then
		__printMessage "Downloading ${IWHITE}${_displayName}${RST} ... " ${false}; _position=($(__getCursorPosition)); __printMessage
		__printMessage "       From:  ${_displayURL%%\?*}"
		__printMessage "  Saving To:  ${_saveFile}"
	else
		__printMessage "Downloading:  ${_url}"
		__printMessage "  Saving To:  ${_saveFile}"
		_position=($(__getCursorPosition))
	fi

	[[ -f "${_saveFile}" ]] && _permissions="$(stat -c "%a" "${_saveFile}")"

	#Limit download rate with "--limit-rate ##k"
	__printDebugMessage "curl --compressed --connect-timeout 5 --create-dirs --fail --location --output \"${_saveFile}.downloading\" --progress-bar --retry 3 --show-error --url \"${_url}\""
	curl --compressed --connect-timeout 5 --create-dirs --fail --location --output "${_saveFile}.downloading" --progress-bar --retry 3 --show-error --url "${_url}" || {
		[[ -n "${_displayName}" ]] && __printStatusMessage ${_position[*]} "${IRED}Failed"
		[[ -f "${_saveFile}.downloading" ]] && rm -f "${_saveFile}.downloading"
		return 1
	}

	if [[ -n "${_displayName}" ]]; then
		__printStatusMessage ${_position[*]} "${IGREEN}Done" ${true}
	else
		__printStatusMessage ${_position[*]} 'Download completed successfully.' ${true}
	fi

	mv -f "${_saveFile}.downloading" "${_saveFile}"

	if [[ -n "${_permissions:-}" ]]; then
		__printDebugMessage "Restoring file permissions (${_permissions})"
		chmod "${_permissions}" "${_saveFile}"
	fi
	__printMessage

	return 0
}

#__enableAutoLogin(User=${USER})
	#Configures autologin as User
	#Return Codes:	0=Success
function __enableAutoLogin() {
	#Dependencies:	__raiseWrongParametersError
	[[ ${#} -gt 1 ]] && __raiseWrongParametersError ${#} 0 1
	local _user="${1:-${USER}}"

	cat >> /etc/init/tty.override <<-EOF
		script
		    if [[ "\${TTY}" == '/dev/tty1' ]]; then
		        exec /sbin/mingetty --noclear --autologin ${_user} \${TTY}
		    else
		        exec /sbin/mingetty \${TTY}
		    fi
		end script
	EOF

	return 0
}

#__getClearScreenState(SilentOutput=${false})
	#Return Codes:	0=Clear Enabled; 1=Clear Disabled
function __getClearScreenState() {
	[[ ${#} -gt 1 ]] && __raiseWrongParametersError ${#} 0 1
	local -i _silentOutput=${1:-${false}}

	(( ! ${_silentOutput} )) && printf "${SUPPRESS_CLEAR}"

	return ${SUPPRESS_CLEAR}
}

#__getCursorPosition()
	#Prints the current cursor position
	#Return Codes:	0
function __getCursorPosition() {
	#Borrowed from: http://unix.stackexchange.com/questions/88296/get-vertical-cursor-position/183121#183121
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0
	local _position

	read -sdR -p $'\E[6n' _position </dev/tty #read from /dev/tty to avoid pulling input redirection text
	printf "${_position#*[}\n" | awk 'BEGIN {FS=";"; OFS=" "}; {print ($1 - 1), ($2 - 1)}'

	return 0
}

#__getDirectoryName(File=${BASH_SOURCE[1]})
	#Prints full path to ${File}
	#Return Codes:	0
function __getDirectoryName() {
	[[ ${#} -gt 1 ]] && __raiseWrongParametersError ${#} 0 1
	local _file="${1:-${BASH_SOURCE[1]}}"

	if [[ -e "${_file}" ]]; then
		printf "$(cd "$(dirname "${_file}")"; pwd)"
	else
		printf "$(dirname "${_file}")"
	fi

	return 0
}

#__getDomainName()
	#Returns kernel.domainname
	#Return Codes:	0=DomainName Set; 1=DomainName Not Set
function __getDomainName() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	sysctl -n kernel.domainname | grep -v '(none)' || return ${?}

	return 0
}

#__getEchoState(SilentOutput=${false})
	#Return Codes:	0=Echo Off; 1=Echo On
function __getEchoState() {
	[[ ${#} -gt 1 ]] && __raiseWrongParametersError ${#} 0 1
	local _echoOn
	local -i _return
	local -i _silentOutput=${1:-${false}}
	local _state

	_state="$(stty -g 2>/dev/null)" #Save current state
	_echoOn="$(stty echo 2>/dev/null && stty -g 2>/dev/null | awk 'BEGIN {FS=":"}; {print $4};')"
	stty "${_state}" 2>/dev/null #Restore state
	_return=$(printf "${_state}" | awk -v _echoOn="${_echoOn}" 'BEGIN {FS=":"} { if($4 == _echoOn) { print "1"; } else { print "0"; } }')

	(( ! ${_silentOutput} )) && printf "${_return}"

	return ${_return}
}

#__getFileName(File=${BASH_SOURCE[1]})
	#Prints file name, removing any path information
	#Return Codes:	0
function __getFileName() {
	[[ ${#} -gt 1 ]] && __raiseWrongParametersError ${#} 0 1
	local _file="${1:-${BASH_SOURCE[1]}}"

	printf "$(basename "${_file}")"

	return 0
}

#__getHostname()
	#Returns kernel.hostname
	#Return Codes:	0=Hostname Set; 1=Hostname Not Set
function __getHostname() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	sysctl -n kernel.hostname | grep -v '(none)' || return ${?}

	return 0
}

#__getInput(PromptMessage, ReplyVariableName, DefaultResponse='', SilentInput=${false}, Pattern='', CaseSensitive=${true})
	#Prompts for input to ${PromptMessage}
		#${ReplyVariableName} value is set with input
		#Global Variable DEFAULT_RESPONSE_AS_INPUT controls placing DefaultResponse in text input or not
	#Return Codes:	0=Success; 99=${INPUT_LIMIT} Reached
	#Exit Codes:	1=Invalid parameter count
function __getInput() {
	#Dependencies:	__getCursorPosition, __getEchoState, __printDebugMessage, __printErrorMessage, __printMessage, __setCursorPosition, __setEchoState
	[[ ${#} -lt 2 || ${#} -gt 6 ]] && __raiseWrongParametersError ${#} 2 6
	local -i _caseSensitive=${6:-${true}}
	local -a _cursorPosition=($(__getCursorPosition))
	local _defaultResponse="${3:-}"
	local -i _echoState=$(__getEchoState)
	local _getInput_input
	local -i _invalidAttemptsCount=0
	local _pattern="${5:-}"
	local _promptMessage="${1:?$(__raiseError 'PromptMessage is required')} ${IWHITE}"
	local _replyVariableName="${2:?$(__raiseError 'ReplyVariableName is required')}"
	local -i _silentInput=${4:-${false}}

	! (( DEFAULT_RESPONSE_AS_INPUT )) && [[ -n "${_defaultResponse}" ]] && _promptMessage+="[${IGREEN}${_defaultResponse}${IWHITE}] "
	_promptMessage="$(printf "${_promptMessage}" | sed -r 's~\x01?(\x1B\(B\x1B\[[m|k]|\x1B\[([0-9]{1,2}(;[0-9]{1,2})*)?[m|K])\x02?~\x01\1\x02~g')" #read requires that colors codes be prefixed with 0x01 and postfixed with 0x02

	while (( ${true} )); do
		tput sgr0 #Reset terminal colors
		if [[ ${INPUT_LIMIT} -eq -1 || ${_invalidAttemptsCount} -lt ${INPUT_LIMIT} ]]; then
			(( ${_silentInput} )) && __setEchoState 0 || __setEchoState 1
			(( FORCE_STDIN )) && __printDebugMessage 'Using forced input from /dev/tty' 
			if (( DEFAULT_RESPONSE_AS_INPUT )); then
				(( FORCE_STDIN )) && read -r -e -i "${_defaultResponse}" -p "${_promptMessage}" '_getInput_input' </dev/tty || read -r -e -i "${_defaultResponse}" -p "${_promptMessage}" '_getInput_input'
			else
				(( FORCE_STDIN )) && read -r -e -p "${_promptMessage}" '_getInput_input' </dev/tty || read -r -e -p "${_promptMessage}" '_getInput_input'
				[[ -z "${_getInput_input}" && -n "${_defaultResponse}" ]] && read '_getInput_input' < <(echo "${_defaultResponse}")
			fi
			__setEchoState ${_echoState}
			[[ -n "${_getInput_input}" ]] && read '_getInput_input' < <(__removeEscapeCodes "${_getInput_input}")
			__setCursorPosition ${_cursorPosition[*]} ${true} #Return to saved cursor position
			(( ${_silentInput} )) && __printDebugMessage "Input: '$(printf '%*s' ${#_getInput_input})'" 2 || __printDebugMessage "Input: '${_getInput_input:-}'" ${true} 2
			if [[ "${_getInput_input,,}" == '+debug' ]]; then #Turn up debugging
				(( ++DEBUG ))
			elif [[ "${_getInput_input,,}" == '-debug' ]]; then #Turn down debugging
				[[ ${DEBUG} -gt 0 ]] && (( --DEBUG ))
			elif (( ${EXIT_CANCELLED:-${false}} )); then
				EXIT_CANCELLED=${false}
			elif [[ ${#} -ge 5 ]]; then #Check input with Pattern
				(( ! ${_caseSensitive} )) && shopt -s nocasematch && __printDebugMessage 'Switching to Case Insensitive Matching' ${true} 2
				[[ -n "${_pattern}" ]] && __printDebugMessage "Matching: ${_getInput_input} =~ ${_pattern}" ${true} 2
				if [[ "${_getInput_input}" =~ ${_pattern} ]]; then
					(( ! ${_caseSensitive} )) && shopt -u nocasematch
					__printDebugMessage "Matched: ${_getInput_input} =~ ${_pattern}"
					break
				elif ! (( FORCE_STDIN )) && ! tty --silent; then
					__printDebugMessage 'No TTY, are you using input redirection?'
					FORCE_STDIN=${true}
				else
					(( ! ${_caseSensitive} )) && shopt -u nocasematch
					(( ++_invalidAttemptsCount ))
					__printErrorMessage "Invalid input (Attempt ${_invalidAttemptsCount} out of ${INPUT_LIMIT})"
				fi
			else
				break
			fi
		else
			__setCursorPosition ${_cursorPosition[*]} ${true} #Return to saved cursor position
			(( _silentInput )) && __printMessage "${1}" || __printMessage "${1}${_getInput_input}"
			__printErrorMessage 'Invalid input attempt limit reached'
			return 99
		fi
	done

	read "${_replyVariableName}" < <(echo "${_getInput_input}")
	(( _silentInput )) && __printMessage "${1}" || __printMessage "${1} ${IWHITE}${!_replyVariableName}"

	return 0
}

#__getIPAddressInput(PromptMessage='IP Address:', ReplyVariableName, DefaultResponse='', AcceptBlank=${false})
	#Prompts for an IPv4 Address
	#Valid inputs are anything in the range of 0.0.0.0 - 255.255.255.255
	#Return Codes:	0=Success; 99=${INPUT_LIMIT} Reached
	#Exit Codes:	1=Invalid parameter count
function __getIPAddressInput() {
	#Dependencies:	__getInput, __raiseError, __raiseWrongParametersError
	[[ ${#} -lt 2 && ${#} -gt 4 ]] && __raiseWrongParametersError ${#} 2 4
	local -i _acceptBlank=${4:-${false}}
	local _defaultResponse="${3:-}"
	local _promptMessage="${1:-'IP Address:'}"
	local _regexPattern="${REGEX_IPADDRESS}"; (( ${_acceptBlank} )) && _regexPattern="^(${REGEX_IPADDRESS})?$"
	local _replyVariableName="${2:?$(__raiseError 'ReplyVariableName is required')}"

	__getInput "${_promptMessage}" "${_replyVariableName}" "${_defaultResponse}" ${false} "${_regexPattern}" || return ${?}

	return 0
}

#__getLastBootTime()
	#Prints the last date & time of the system boot
	#	Output Format:	YYYYMMDDHHmm
	#Return Codes:	0
	#Exit Codes:	1=Invalid parameter count
function __getLastBootTime() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	printf $(who -b | awk '{gsub("-", "", $3); gsub(":", "", $4); print $3$4}')

	return 0
}

#__getMenuInput(PromptMessage, ChoicesArrayName, ReplyVariableName, DefaultResponse='', ResponseStyle=${INPUT_RETURN_STYLE})
	#Prompts for selection to ${PromptMessage} from ${Choices} array
	#Return Codes:	0=Success; 99=${INPUT_LIMIT} Reached
	#Exit Codes:	1=Invalid parameter count
function __getMenuInput() {
	[[ ${#} -lt 3 || ${#} -gt 5 ]] && __raiseWrongParametersError ${#} 3 5
	local -a _choices
	local _choicesArrayName="${2:?$(__raiseError "ChoicesArrayName is required")}[@]"
	local _defaultResponse="${4:-}"
	local -a _entries #Populated by private__setEntries
	local -a _multipleChoiceArray #Used to pass excepted options to __getMultipleChoiceInput
	local _promptMessage="${1:?$(__raiseError "PromptMessage is required")}"
	local _replyVariableName="${3:?$(__raiseError "ReplyVariableName is required")}"
	local -i _responseStyle=${INPUT_RETURN_STYLE}; [[ ${#} -eq 5 && "${5}" =~ ^[0-3]$ ]] && _responseStyle=${5}

	function private__setEntries() {
		local _choice
		local _displayChoice
		local _displayValue
		local _entryFormat="${IWHITE}%4b${RST}) %-b${RST}"
		local -i _indexDisplay=1 #Starting value for item numbers

		for _choice in "${_choices[@]}"; do
			[[ ${_responseStyle} -ne ${INPUT_RETURN_STYLE_SELECTED_INPUT} ]] && _displayChoice=$'\t'
			case "${_choice:0:2}" in
				'') _entries+=('') ;; #Empty Line
				'--') #Hidden Option
					if ! [[ "${_choice:2}" =~ ^(--)+.+$ ]]; then #Is the entry more than just hidden?
						[[ "${_choice}" =~ ^(--)+(__|==|##|\*\*|\+\+|[^=]+=)+.+$ ]] || (( ++_indexDisplay )) #If not hidden, would this entry use a index number?
					fi
					;;
				'==') #Column Headings
					[[ -n "${_entries[@]:-}" && ${#_entries[@]} -ne 0 ]] && _displayValue="\n"
					_displayValue+="      ${IWHITE}${UNDR}${_choice:2}${RST}"
					_entries+=("${_displayValue}")
					__isColorsLoaded || {
						printf -v line '%*s' $(__removeEscapeCodes "${_choice:2}" | wc -m)
						_entries+=("      $(printf '%s\n' "${line// /-}")")
					}
					;;
				'__') #Section Title
					[[ ${#_entries[@]} -ne 0 ]] && _displayValue="\n"
					_displayValue+="  ${IWHITE}${UNDR}${_choice:2}${RST}"
					_entries+=("${_displayValue}")
					__isColorsLoaded || {
						printf -v line '%*s' $(__removeEscapeCodes "${_choice:2}" | wc -m)
						_entries+=("  $(printf '%s\n' "${line// /-}")")
					}
					;;
				'##') #Help Messages
					if (( PRINT_MENU_COMMENTS )); then
						if [[ -n "${_choice:2}" ]]; then
							_entries+=("        ${_choice:2}")
						else
							_entries+=('')
						fi
					fi
					;;
				'**') #Comments/Notes
					_displayValue="        ${_choice:2}"
					_entries+=("${_displayValue}")
					;;
				'++') #Can not be selected
					_displayValue="      ${_choice:2}"
					_entries+=("${_displayValue}")
					;;
				*) #Normal entry
					_displayValue="${_choice#*=}"
					if [[ "${_displayValue}" != "${_choice}" ]]; then
						_displayChoice="${_choice%%=*}"
					else
						_displayChoice="${_indexDisplay}"
						(( ++_indexDisplay ))
					fi
					_entries+=("$(printf "${_entryFormat}" "${_displayChoice}" "${_displayValue}")")
					;;
			esac
			[[ -n "${_displayChoice:-}" ]] && {
				_multipleChoiceArray+=("${_displayChoice}")
				unset _displayChoice
			}
		done
	}

	function private__printEntries() {
		local _entry1 _entry2
		local _entryTemp
		local -i i
		local IFS

		if [[ ${#_entries[@]} -le ${MAX_SINGLE_COLUMN_OPTIONS} ]]; then #Print single column
			IFS=';' && __logMessage "Menu Entries: ${_entries[*]}"
			IFS=$'\n' && printf '%b\n' "${_entries[*]}"
			unset IFS
		else
			for ((i = 0; i < ${#_entries[@]}; i++)); do
				_entry1="${_entries[${i}]}"
				[[ ${#_entries[@]} -gt $((i + 1)) ]] && _entry2="${_entries[$((i + 1))]}" || _entry2=""

				if [[ -z "${_entry1}" ]]; then
					__printDebugMessage "Empty Entry1" ${true} 2
					__printMessage
				elif [[ -z "${_entry2}" ]]; then
					__printDebugMessage "Empty Entry2" ${true} 2
					__printMessage "${_entry1}"
				elif [[ $(__removeEscapeCodes "${_entry1}" | wc -m) -gt ${MAX_COLUMN_WIDTH} ]]; then
					__printDebugMessage "Long Entry1 ($(__removeEscapeCodes "${_entry1}" | wc -m)): '${_entry1}'" ${true} 2
					__printMessage "${_entry1}"
				elif [[ $(__removeEscapeCodes "${_entry2}" | wc -m) -gt ${MAX_COLUMN_WIDTH} ]]; then
					__printDebugMessage "Short Entry1 ($(__removeEscapeCodes "${_entry1}" | wc -m)): '${_entry1}'" ${true} 2
					__printDebugMessage "Long Entry2 ($(__removeEscapeCodes "${_entry2}" | wc -m)): '${_entry2}'" ${true} 2
					__printMessage "${_entry1}"
					__printMessage "${_entry2}"
					(( ++i ))
				elif [[ "${_entry1//\\n/}" != "${_entry1}" ]]; then
					__printDebugMessage "New line detected in Entry1" ${true} 2 #Section titles do this automatically
					if [[ ${i} -eq 0 ]]; then
						__printMessage "${_entry1:1}"
					else
						__printMessage "${_entry1}"
					fi
				elif [[ "${_entry2//\\n/}" != "${_entry2}" ]]; then
					__printDebugMessage "New line detected in Entry2" ${true} 2 #Section titles do this automatically
					__printMessage "${_entry1}"
					__printMessage "${_entry2}"
					(( ++i ))
				else
					__printDebugMessage "Two Column Output" ${true} 2
					_entryTemp="$(__removeEscapeCodes "${_entry1}")"
					_entry1+="$(printf "%$((MAX_COLUMN_WIDTH - ${#_entryTemp}))s" '')" #Workaround: Pad first column value with spaces because printf counts non-printed characters in padded fields
					if [[ ${i} -eq 0 && "${_choices[0]:0:2}" == '==' ]]; then
						__printMessage "${_entry1}${RST}  ${_entry1}"
					else
						__printMessage "${_entry1}  ${RST}${_entry2}"
						(( ++i ))
					fi
				fi
			done
		fi
	}

	_choices=("${!_choicesArrayName}")
	private__setEntries
	private__printEntries

	__printMessage

	if [[ ${_responseStyle} -eq ${INPUT_RETURN_STYLE_SELECTED_VALUE} ]]; then
		__getMultipleChoiceInput "${_promptMessage}" '_multipleChoiceArray' "${_replyVariableName}" "${_defaultResponse}" ${false} ${false} ${INPUT_RETURN_STYLE_SELECTED_INDEX} || return ${?}
		read ${_replyVariableName} <<<"${_choices[${!_replyVariableName}]}"
	else
		__getMultipleChoiceInput "${_promptMessage}" '_multipleChoiceArray' "${_replyVariableName}" "${_defaultResponse}" ${false} ${false} ${_responseStyle} || return ${?}
	fi

	return 0
}

#__getMultipleChoiceInput(PromptMessage, ChoicesArrayName, ReplyVariableName, DefaultResponse='', PrintChoices=${true}, PartialMatch=${true}, ResponseStyle=${INPUT_RETURN_STYLE})
	#Prompts for a response to prompt message
		#with a value from choices array
		#When PrintChoices is true, the choices list will be presented
		#When PartialMatch is true, only partial input is required to match a value
			#Can cause issues if two choices start with the same value and the first is longer than the second
	#Return Codes:	0=Success; 99=${INPUT_LIMIT} Reached
	#Exit Codes:	1=Invalid parameter count
function __getMultipleChoiceInput() {
	[[ ${#} -lt 3 || ${#} -gt 7 ]] && __raiseWrongParametersError ${#} 3 7
	local -a _choices
	local _choicesArrayName="${2:?$(__raiseError "ChoicesArrayName is required")}[@]"
	local _choicesList
	local _defaultResponse="${4:-}"
	local _getMultipleChoiceInput_input
	local -i _partialMatch=${6:-${true}}
	local -i _printChoices=${5:-${true}}
	local _promptMessage="${1:?$(__raiseError "PromptMessage is required")}"
	local _regexPattern
	local _replyVariableName="${3:?$(__raiseError "ReplyVariableName is required")}"
	local -i x y
	local -i _responseStyle=${INPUT_RETURN_STYLE}; [[ ${#} -eq 7 && "${7}" =~ ^[0-3]$ ]] && _responseStyle=${7}
	local IFS

	#private__setReplyVariable(index, typed, value)
	function private__setReplyVariable() {
		local _index="${1}"
		local _typed="${2}"
		local _value="${3}"

		__printDebugMessage "_index=${_index:-unset}" ${true} 2
		__printDebugMessage "_type=${_typed:-unset}" ${true} 2
		__printDebugMessage "_value=${_value:-unset}" ${true} 2

		case ${_responseStyle} in
			${INPUT_RETURN_STYLE_SELECTED_INDEX}) read ${_replyVariableName} <<<${_index} ;;
			${INPUT_RETURN_STYLE_SELECTED_INPUT}) read ${_replyVariableName} <<<"${_value}" ;;
			${INPUT_RETURN_STYLE_SELECTED_VALUE}) read ${_replyVariableName} <<<"${_value}" ;;
			${INPUT_RETURN_STYLE_TYPED_INPUT}) read ${_replyVariableName} <<<"${_typed}" ;;
		esac

		__printDebugMessage "Response Style: ${_responseStyle}" ${true} 2
		__printDebugMessage "Response Value: ${!_replyVariableName}" ${true} 2

		return 0
	}

	_choices=("${!_choicesArrayName}")
	if (( _printChoices )); then
		_choicesList="$(printf "/%s" "${_choices[@]}")"
		_promptMessage="${_promptMessage} ${IWHITE}(${_choicesList:1})"
	fi

	if (( _partialMatch )); then
		for x in "${!_choices[@]}"; do #Build RegEx to pass to __getInput for input validation
			for ((y = ${#_choices[${x}]}; y > 0; y--)); do #Step through characters of _choice
				_regexPattern+="|${_choices[${x}]:0:${y}}"
			done
			_regexPattern+="|${_choices[${x}]}"
		done
		_regexPattern="^(${_regexPattern:1})$" #Remove first character
	else
		IFS='|'; _regexPattern="^(${_choices[*]})$"; unset IFS
	fi

	__printDebugMessage "_regexPattern = '${_regexPattern}'"

	__getInput "${_promptMessage}" '_getMultipleChoiceInput_input' "${_defaultResponse}" ${false} "${_regexPattern}" ${false} || return ${?}
	__printDebugMessage "Match Style: $((( _partialMatch )) && printf 'Partial' || printf 'Full')"
	for x in "${!_choices[@]}"; do
		if (( _partialMatch )) && [[ "${_choices[${x}],,}" =~ ^"${_getMultipleChoiceInput_input,,}".*$ ]]; then
			__printDebugMessage "Partial Match: '${_choices[${x}],,}' =~ '${_getMultipleChoiceInput_input,,}'"
			private__setReplyVariable "${x}" "${_getMultipleChoiceInput_input}" "${_choices[${x}]}"
			#(( ${_responseStyle} )) && read ${_replyVariableName} <<<${x} || read ${_replyVariableName} <<<"${_choices[${x}]}"
			return 0
		elif ! (( _partialMatch )) && [[ "${_choices[${x}],,}" == "${_getMultipleChoiceInput_input,,}" ]] ; then
			__printDebugMessage "Full Match: '${_choices[${x}],,}' == '${_getMultipleChoiceInput_input,,}'"
			private__setReplyVariable "${x}" "${_getMultipleChoiceInput_input}" "${_choices[${x}]}"
			#(( ${_responseStyle} )) && read ${_replyVariableName} <<<${x} || read ${_replyVariableName} <<<"${_choices[${x}]}"
			return 0
		else
			__printDebugMessage "No Match: '${_choices[${x}],,}' != '${_getMultipleChoiceInput_input,,}'" ${true} 2
		fi
	done
	__printErrorMessage "An input of '${_getMultipleChoiceInput_input}' was not found in '${_choices[@]}'. Exiting" ${true} 1
}

#__getNewVLANConfigFileName(MasterInterface, VLAN)
	#Generates VLAN interface configuration file name based on VLAN Naming Type
	#Return Codes:	0=Success
function __getNewVLANConfigFileName() {
	[[ ${#} -ne 2 ]] && __raiseWrongParametersError ${?} 2
	local _masterInterface="${1:?$(__raiseError 'MasterInterface is required')}"
	local -i _vlan=${2:?$(__raiseError 'VLAN is required')}
	local _vlanStyle="${VLAN_NAME_TYPES[${VLAN_NAME_TYPE}]}"

	printf '%s' "${SYSCONFIG_NETWORK_SCRIPTS}/ifcfg-$([[ "${_vlanStyle:0:1}" == '%' ]] && printf "${_vlanStyle}" "${_masterInterface}" ${_vlan} || printf "${_vlanStyle}" ${_vlan})"
	
	return 0
}

#__getVLANConfigFileName(MasterInterface, VLAN)
	#Checks each VLAN Naming Style to locate an existing network configuration file
	#Return Codes:	0=Found; 1=No Configuration Found
function __getVLANConfigFileName() {
	[[ ${#} -ne 2 ]] && __raiseWrongParametersError ${?} 2
	local _masterInterface="${1:?$(__raiseError 'MasterInterface is required')}"
	local -i _vlan=${2:?$(__raiseError 'VLAN is required')}
	local _vlanStyle

	for _vlanStyle in "${VLAN_NAME_TYPES[@]}"; do
		__printDebugMessage "Checking '${_vlanStyle}' with ${_masterInterface} and ${_vlan}: $([[ "${_vlanStyle:0:1}" == '%' ]] && printf "${_vlanStyle}" "${_masterInterface}" ${_vlan} || printf "${_vlanStyle}" ${_vlan})"
		if [[ -f "${SYSCONFIG_NETWORK_SCRIPTS}/ifcfg-$([[ "${_vlanStyle:0:1}" == '%' ]] && printf "${_vlanStyle}" "${_masterInterface}" ${_vlan} || printf "${_vlanStyle}" ${_vlan})" ]]; then
			printf '%s' "${SYSCONFIG_NETWORK_SCRIPTS}/ifcfg-$([[ "${_vlanStyle:0:1}" == '%' ]] && printf "${_vlanStyle}" "${_masterInterface}" ${_vlan} || printf "${_vlanStyle}" ${_vlan})"
			return 0
		fi
	done

	return 1
}

#__getYesNoInput(PromptMessage, DefaultResponse='')
	#Prompts for a yes or no response to ${PromptMessage}
	#Return Codes:	0=Yes; 1=No; 99=${INPUT_LIMIT} Reached
	#Exit Codes:	1=Invalid parameter count
function __getYesNoInput() {
	[[ ${#} -lt 1 || ${#} -gt 2 ]] && __raiseWrongParametersError ${#} 1 2
	local _defaultResponse="${2:-}"
	local _promptMessage="${1:?$(__raiseError 'PromptMessage is required')}"
	local -a _yesno=('Yes' 'No')
	local _reply

	if __getMultipleChoiceInput "${_promptMessage}" '_yesno' '_reply' "${_defaultResponse}"; then
		__printDebugMessage "_reply='${_reply}'"
		case "${_reply,,}" in
			'yes'|0)
				return 0
				;;
			'no'|1)
				return 1
				;;
		esac
	else
		return ${?} #Returns the return code from __getMultipleChoiceInput
	fi
}

#__getVersion()
	#Prints the value of ${VERSION} from the calling script file
	#Return Codes:	0
function __getVersion() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	if __isSourced "${BASH_SOURCE[1]}"; then
		printf "$(sed -nr "/^declare VERSION=/s~^declare VERSION=['\"]?([^'\"]*)['\"]?~\1~p" ${BASH_SOURCE[1]})"
	else
		printf "${VERSION}"
	fi

	return 0
}

#__installPackage(PackageName)
	#Installs the specified PackageName
	#Returns:  0=success/already installed, 1=failure
function __installPackage() {
	[[ ${#} -lt 1 || ${#} -gt 2 ]] && __raiseWrongParametersError ${#} 1 2
	local -a _cursorPosition
	local _package
	local _packageName="${1:?$(__raiseError 'PackageName is required')}"
	local -a _packages=(${_packageName})

	#Need to check each package individually as some might be installed and others not
	__printDebugMessage "${IWHITE}Checking for already installed package(s)"
	for _package in ${!_packages[@]}; do
		__printDebugMessage "\tChecking Package:  ${IWHITE}${_packages[${_package}]}${RST} ... " ${false}
		if __checkInstalledPackage "${_packages[${_package}]}"; then
			__printDebugMessage "${IRED}Installed"
			unset _packages[${_package}] #Strip out packages that are installed from the list
		else
			__printDebugMessage "${IGREEN}Not Installed"
		fi
	done
	_packages=(${_packages[*]:-})

	if [[ ${#_packages[@]} -gt 0 ]]; then #Try installing from bundled sources first
		__printMessage "Installing ${IWHITE}${_packages[*]}${RST} ..." ${false}; _cursorPosition=($(__getCursorPosition)); __printMessage
		if yum -y -q --nogpgcheck install ${_packages[*]} 2>/dev/null; then
			__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done" ${true}
		else
			__printStatusMessage ${_cursorPosition[*]} "${IRED}Failed"
			return 1
		fi
	fi

	return 0
}

#__installRPM(RPMFileName)
	#Installs RPMFileName
	#Return Codes:	0=Success; 1=Failed Install
	#Exit Codes:	1=Invalid parameter; 255=RPM file not found
function __installRPM() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _output
	local _rpmFile="${1:?$(__raiseError 'RPMFileName is required')}"

	if [[ "${_rpmFile}" != "${_rpmFile//\*/}" ]]; then
		__printDebugMessage "Resolving wildcard to first match (${_rpmFile})"
		_rpmFile=$(ls -1 ${_rpmFile} 2>/dev/null | head -n 1)
	fi

	[[ ! -f "${_rpmFile}" ]] && __raiseError "RPM File (${_rpmFile}) not found." 255

	__printMessage "Installing '${IWHITE}${_rpmFile##*/}${RST}' ... " ${false}
	if _output=$(rpm -iU --nodeps "${_rpmFile}" 2>&1); then
		__printMessage "${IGREEN}Done"
	else
		case ${?} in
			1) __printMessage "${IGREEN}Already Installed" ;;
			2)
				_output="${_output##*package }"
				_output="${_output%% *}"
				__printMessage "${IYELLOW}Newer Version Installed (${_output})"
				;;
			*)
				__printMessage "${IRED}Failed (${?})"
				return 1
				;;
		esac
	fi

	return 0
}

#__intToIP(Integer)
	#Converts integer to IP dotted format
function __intToIP() {
        [[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
        local -a _ipArray
        local -i _int=${1:?$(__raiseError 'Integer is required')} 
        local IFS='.'

        _ipArray[0]=$(( (${_int} / (256**3)) % 256 ))
        _ipArray[1]=$(( (${_int} / (256**2)) % 256 ))
        _ipArray[2]=$(( (${_int} / 256) % 256 ))
        _ipArray[3]=$(( ${_int} % 256 ))

        printf '%s' "${_ipArray[*]}"
}

#__ipToInt(IPAddress)
	#Converts IP dotted format to integer
function __ipToInt() {
        [[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
        local IFS='.'
        local -i _int=0 i
        local _ip="${1:?$(__raiseError 'IPAddress is required')}"
        local -a _ipArray

        _ipArray=(${_ip})

        _int=${_ipArray[3]}
        _int+=$(( ${_ipArray[2]} * 256 ))
        _int+=$(( ${_ipArray[1]} * (256**2) ))
        _int+=$(( ${_ipArray[0]} * (256**3) ))

        printf '%s' "${_int}"
}

#__isBeta()
	#Return Codes:	0=Is a beta release; 1=Is not a beta release
function __isBeta() {
	return $([[ "${VERSION_STATE:-}" == 'beta' ]])
}

#__isColorsLoaded()
	#Return Codes:	0=Loaded; 1=Unloaded
function __isColorsLoaded() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	return $([[ "${RST:-}" == "$(tput sgr0)" ]])
}

#__isDebugEnabled()
	#Return Codes:	0=Enabled; 1=Disabled
function __isDebugEnabled() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	(( DEBUG )) && return 0 || return 1
}

#__isSourced(Script=${BASH_SOURCE[1]})
	#If script is not supplied, defaults to using function callers script
	#Return Codes:	0=Sourced; 1=Executed
function __isSourced() {
	[[ ${#} -gt 1 ]] && __raiseWrongParametersError ${#} 0 1
	local _script="${1:-${BASH_SOURCE[1]}}"

	[[ "${0}" == "${_script}" ]] && return 1
	[[ -f "$(__getDirectoryName "${0}")/${0}" && "$(__getDirectoryName "${0}")/${0}" == "${_script}" ]] && return 1
	[[ "$(which "${0}")" == "${_script}" ]] && return 1

	return 0
}

#__loadColors()
	#declares several variables for color terminal output
	#Return Codes:	0
function __loadColors() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	__isDebugEnabled && __printMessage 'Loading Color Variables ... ' ${false}

	BOLD="$(tput bold)"						# Bold text only, keep color
	BOLD_STOP="$(tput dim || tput sgr0)"	# Turn off bold, keep color
	UNDR="$(tput smul)"						# Underline text only, keep color
	UNDR_STOP="$(tput rmul)"				# Turn off underline text only, keep color
	INV="$(tput rev)"						# Inverse: swap background and foreground colors
	RST="$(tput sgr0)"						# Reset all coloring and style

	BLACK="$(tput setaf 0)"
	ONBLACK="$(tput setab 0)"
	RED="$(tput setaf 1)"
	ONRED="$(tput setab 1)"
	GREEN="$(tput setaf 2)"
	ONGREEN="$(tput setab 2)"
	YELLOW="$(tput setaf 3)"
	ONYELLOW="$(tput setab 3)"
	BLUE="$(tput setaf 4)"
	ONBLUE="$(tput setab 4)"
	PURPLE="$(tput setaf 5)"
	ONPURPLE="$(tput setab 5)"
	CYAN="$(tput setaf 6)"
	ONCYAN="$(tput setab 6)"
	WHITE="$(tput setaf 7)"
	ONWHITE="$(tput setab 7)"

	IBLACK="${BLACK}${BOLD}${ONWHITE}"
	IBLUE="${BLUE}${BOLD}"
	ICYAN="${CYAN}${BOLD}"
	IGREEN="${GREEN}${BOLD}${ONBLACK}"
	IPURPLE="${PURPLE}${BOLD}"
	IRED="${RED}${BOLD}"
	IWHITE="${WHITE}${BOLD}${ONBLACK}"
	IYELLOW="${YELLOW}${BOLD}"

	__isDebugEnabled && __printMessage "${IGREEN}Done${RST}"

	return 0
}

#__loadKernelModule(ModuleName)
	#Checks if the module is loaded, if not it will attempt to load it
	#Return Codes:	0=Loaded Successfully; 1=Failed to Load
function __loadKernelModule() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local IFS
	local _module="${1:?$(__raiseError 'ModuleName is required')}"

	if ! lsmod | grep -i -q "${_module}"; then
		modprobe "${_module}" || return 1
		[[ "${_module,,}" == 'bonding' ]] && echo '-bond0' > /sys/class/net/bonding_masters 2>/dev/null || :
	fi

	return 0
}

#__logMessage(Message='', LogFile=${BASH_SOURCE[1]}.log)
	#Logs Message to LogFile
function __logMessage() {
	[[ ${#} -gt 2 ]] && __raiseWrongParametersError ${#} 0 2
	local IFS
	local -a _caller=($(caller 0))
	local _date="$(date -u +%FT%T)"
	local -i _frame=1
	local _logFile="${2:-${BASH_SOURCE[1]}.log}"
	local _message="${1:-}"
	local -i _pid=${$}

	#_caller[0] => Line Number; _caller[1] => Function Name; _caller[2] => Script Name

	while [[ "${_caller[1]}" =~ ^(private\_\_|\_\_print).*$ ]]; do
		if caller ${_frame} >/dev/null 2>&1; then
			_caller=($(caller ${_frame}))
			(( ++_frame ))
		else
			break
		fi
	done

	[[ ${BASHPID:-} -ne 0 ]] && _pid=${BASHPID}

	#Date|ProcessID|ScriptName|FunctionName|LineNumber|DebugLevel|Message
	[[ "$(__getFileName "${_caller[2]}")" == "$(__getFileName)" ]] && _caller[2]="$(__getFileName)"
	printf '%s|%d|%s|%s|%d|%d|%b\n' "${_date}" "${_pid}" "${_caller[2]}" "${_caller[1]}" "${_caller[0]}" "${DEBUG}" "$(__removeEscapeCodes "${_message}")" >> "${_logFile}"

	return 0
}

#__modifyFileContents(FileName, SearchValue, ReplaceValue, Append=${true})
	#Change all occurrences of SearchValue with ReplaceValue within FileName
	#Optionally append the ReplaceValue when not found in FileName and Append is true
function __modifyFileContents() {
	[[ ${#} -lt 3 || ${#} -gt 4 ]] && __raiseWrongParametersError ${#} 3 4

	local -i _append="${4:-${true}}"
	local _filename="${1:?$(__raiseError 'FileName is required')}"
	local _replaceValue="${3:?$(__raiseError 'ReplaceValue is required')}"
	local _searchValue="${2:?$(__raiseError 'SearchValue is required')}"

	if [[ -f "${_filename}" || ${_append} -eq ${true} ]]; then
		[[ ! -f ${_filename} ]] && __createFile "${_filename}" >/dev/null
		if grep -E -i -q "${_searchValue}" "${_filename}"; then
			__logMessage "Updating '${_filename}': '${_searchValue}' => '${_replaceValue}'"
			sed -i -r -e "s~${_searchValue}~${_replaceValue}~gI" "${_filename}"
		elif (( ${_append} )); then
			__logMessage "Appending '${_replaceValue}' to '${_filename}'"
			printf '%s\n' "${_replaceValue}" >> "${_filename}"
		else
			__logMessage "'${_filename}' exists, but append is not true and '${_searchValue}' was not found."
		fi
	else
		__logMessage "'${_filename}' not found and append is not true"
	fi

	return 0
}

#__netmaskToBitmask(Netmask)
	#Converts Netmask to Bitmask
	#Return Codes:	0=Success
	#Exit Codes:	254=Wrong Parameter Count; 255=Invalid Netmask value
function __netmaskToBitmask() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local -i _bits=0
	local _netmask="${1:?$(__raiseError 'Netmask is required')}"
	local -a _netmaskArray
	local _octet

	[[ "${_netmask}" =~ ${REGEX_IPADDRESS} ]] || __raiseError "${_netmask} is not a valid Network Mask"

	IFS="." read -a _netmaskArray <<< "${_netmask}"
	for _octet in ${_netmaskArray[@]}; do
		case "${_octet}" in
			'255') _bits+=8;;
			'254') _bits+=7; break;;
			'252') _bits+=6; break;;
			'248') _bits+=5; break;;
			'240') _bits+=4; break;;
			'224') _bits+=3; break;;
			'192') _bits+=2; break;;
			'128') _bits+=1; break;;
			'0') break;;
		esac
	done

	printf '%s' "${_bits}"

	return 0
}

#__onError()
	#Is used to trap errors and prints out more information to troubleshoot the issue
	#Exit Codes:	255=Unhandled Error
function __onError() {
	local -i _exitCode=255
	local _message='Unhandled Error Occurred'

	__printErrorMessage "${_message}"
	printf "\r"
	tput ed
	__printStackTrace
	exit ${_exitCode}
}

#__pause(Force=${false})
	#Pauses until a user press any key
	#If input redirection is being used, no pausing will take place unless Force is ${true}
	#Return Codes:	0
function __pause() {
	#Dependencies:	__getCursorPosition, __getEchoState, __raiseWrongParametersError, __setCursorPosition, __setEchoState
	[[ ${#} -gt 1 ]] && __raiseWrongParametersError ${#} 0 1
	local -i _force=${1:-${false}}
	local IFS

	if (( _force )) || tty --silent; then
		local -i _echoState="$(__getEchoState)"
		local -a _position=($(__getCursorPosition))

		__setEchoState 0
		read -n 1 -p "${IWHITE}Press any key to continue ...${RST}" -r </dev/tty #read from /dev/tty to avoid pulling input redirection text
		__setEchoState ${_echoState}
		__setCursorPosition ${_position[*]} ${true}
	fi

	return 0
}

#__printDebugMessage(Message='', Newline=${true}, MinimumDebugLevel=1)
	#Calls __printMessage with debug default values
function __printDebugMessage() {
	__printMessage "${1:-}" ${2:-${true}} ${3:-1}
}

#__printErrorMessage(Message, Newline=${true}, ExitCode=-1)
	#Prints ${Message} to stderr (&2)
	#	Adds "\n" if ${Newline} is true
	#	If ${ExitCode} is >= 0, the function will exit with ${ExitCode}
	#Return Codes:	0
	#Exit Codes:	1=Invalid parameter count; ${ExitCode} when >= 0
function __printErrorMessage() {
	[[ ${#} -lt 1 || ${#} -gt 3 ]] && __raiseWrongParametersError ${#} 1 3
	local IFS
	local -a _caller=($(caller 0))
	local _message="${1:?$(__raiseError 'Message is required')}"
	local -i _newline=${2:-${true}}
	local -i _exitCode=${3:--1}

	if __isDebugEnabled; then
		__printMessage "${IYELLOW}DEBUG: ${_caller[2]:-}: ${_caller[1]} (line: ${_caller[0]})${RST}" ${false} >&2
		__printMessage " | ${IRED}ERROR: ${RED}${_message}${RST}" "${_newline}" >&2
	else
		__printMessage "${IRED}ERROR: ${RED}${_message}${RST}" "${_newline}" >&2
	fi

	[[ ${_exitCode} -ge 0 ]] && exit ${_exitCode}

	return 0
}

#__printFunctionUsage(ExitCode=-1, ErrorMessage='', Script=${BASH_SOURCE[1]}, Function=${FUNCNAME[1]})
	#Prints commented lines preceeding ${Function} declaration from ${Script}
	#	If ${ExitCode} is >= 0, the function will exit with ${ExitCode}
	#Return Codes:	0
	#Exit Codes:	1=Invalid parameter count; ${ExitCode} when >- 0
function __printFunctionUsage() {
	[[ ${#} -gt 4 ]] && __raiseWrongParametersError ${#} 0 4
	local IFS
	local -a _caller=($(caller 0))
	local -i _exitCode=${1:--1}
	local _errorMessage="${2:-}"
	local _function="${4:-${FUNCNAME[1]}}"
	local _script="${3:-${BASH_SOURCE[1]}}"
	local _usageLines

	if [[ -f "$(__getDirectoryName "${_script}")/$(__getFileName "${_script}")" ]]; then
		__printDebugMessage "pcregrep -M \"(^\s*(#.*)?$\\\n)+^function ${_function}\(\)\" \"$(__getDirectoryName "${_script}")/$(__getFileName "${_script}")\" | sed -n -r 's~^(\s*|(\s*)#(.*))$~\\\2\\\3~gp'"
		_usageLines="$(pcregrep -M "(^\s*(#.*)?$\n)+^function ${_function}\(\)" "$(__getDirectoryName "${_script}")/$(__getFileName "${_script}")" | sed -n -r 's~^(\s*|(\s*)#(.*))$~\t\2\3~gp')"

		__printMessage "$(__getDirectoryName "${_script}")/$(__getFileName "${_script}") " ${false}
		__printMessage "Function ${IWHITE}\"${_function}\"${RST} Usage Information:"
		__printMessage "${_usageLines}"
	else
		__printErrorMessage "${_script} was not found" 1
	fi

	[[ -n "${_errorMessage}" ]] && __printErrorMessage "${_errorMessage}" ${true} ${_exitCode}
	[[ ${_exitCode} -ge 0 ]] && exit ${_exitCode}

	return 0
}

#__printInterfaceConfigValue(Interface, VariableName)
	#Sources the Interface configuration file and prints the value of VariableName
	#Return Codes:	0=Success
	#Exit Codes:	254=Invalid Parameter
function __printInterfaceConfigValue() {
	[[ ${#} -ne 2 ]] && __raiseWrongParametersError ${#} 2
	local _interface="${1:?$(__raiseError 'Interface is required')}"
	local _variableName="${2:?$(__raiseError 'VariableName is required')}"

	if [[ -f "${SYSCONFIG_NETWORK_SCRIPTS}/ifcfg-${_interface}" ]]; then
		source "${SYSCONFIG_NETWORK_SCRIPTS}/ifcfg-${_interface}"
		printf "${!_variableName:-}" || :
	fi

	return 0
}

#__printInterfaceIPAddress(Interface, CIDRFormat=${true})
	#Prints the first IP Address of Interface
	#Return Codes:	0=Success; 1=Invalid interface
function __printInterfaceIPAddress() {
	[[ ${#} -lt 1 || ${#} -gt 2 ]] && __raiseWrongParametersError ${#} 1 2
	local _interface="${1:?$(__onError 'Interface is required')}"
	local -i _cidrFormat=${2:-${true}}

	[[ "$(__printInterfaceList)" =~ "${_interface}" ]] || return 1 #Interface doesn't exist
	(( ${_cidrFormat} )) && {
		ip --family inet --oneline address show dev "${_interface}" 2>/dev/null | awk 'NR==1 {print $4};'
	} || {
		ip --family inet --oneline address show dev "${_interface}" 2>/dev/null | awk 'NR==1 {gsub(/\/.*$/, "", $4); print $4};'
	}

	return 0
}

#__printInterfaceList()
	#Returns a list of all interfaces in the system
	#Return Codes:	0=Success
	#Exit Codes:	254=Invalid parameter count
function __printInterfaceList() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0
	
	ip --details --oneline link show | awk 'BEGIN {FS=": "} {print $2};'

	return 0
}

#__printNetworkInterfaceDetails(PrintHeadings=${false}, ShowLoopback=${false})
function __printNetworkInterfaceDetails() {
	[[ ${#} -gt 2 ]] && __raiseWrongParametersError ${#} 0 2
	local IFS
	local -i _printHeadings=${1:-${false}} _showLoopback=${2:-${false}}
	local _details _interface _status _previousInterface
	local _runningIPAddress _configuredIPAddress
	local _state _mode
	local _linkAddressMode _linkMaster _linkMode _linkSpeed _linkState _linkType
	local _outputFormat='%s\t%s\t%s\t%s\t%s\t%s\t%s\n'

	(( _printHeadings )) && printf "${_outputFormat}" 'Interface' 'IP Address' 'State' 'Type' 'Mode' 'Master' 'Speed'

	while read _interface _status _details; do
		[[ "${_interface}" == "${_previousInterface:-}" ]] && continue #Skip the second one since we can't fix how sort and join sort differently
		[[ "${_interface}" != "${_interface%.new}" ]] && continue #Hide temp configuration files
		_interface="${_interface%%@*}"
		! (( _showLoopback )) && [[ "${_interface}" == 'lo' ]] && continue
		_runningIPAddress="$(__printInterfaceIPAddress "${_interface}" || :)"
		_status="${_status:1:$((${#_status} -2 ))}" #Strip off leading '<' and trailing '>'

		#Reset to useful defaults
		_linkAddressMode='--'
		_linkMaster='--'
		_linkMode='--'
		_linkSpeed='--'
		_linkState='Down'
		_linkType='--'

		for _state in ${_status//,/ }; do
			case "${_state,,}" in #http://www.policyrouting.org/iproute2.doc.html#ss9.1
				'allmulti'|'broadcast'|'dynamic'|'m-down'|'multicast'|'noarp'|'promisc'|'up') __printDebugMessage "Ignored State: ${_state}" ${true} 2;;
				'cfg-file') : ;;
				'loopback')
					_linkAddressMode='Static'
					_linkType='Loopback'
					;;
				'lower_up') _linkState='Up';;
				'master') _linkType='Bond';;
				'no-carrier') _linkState='No-Link';;
				'pointopoint') _linkType='P2P';;
				'slave')
					_linkMaster="${_details/#* master }"
					_linkMaster="${_linkMaster/% *}"
					_linkType='Bond'
					_linkMode='Slave'
					;;
				*) __printErrorMessage "Unhandled State: ${_state}";;
			esac
		done

		#Get VLAN Details
		if [[ "${_details}" != "${_details/#* vlan id }" ]]; then
			_linkMode="${_details/#* vlan id }"
			_linkMode="${_linkMode/% *}"
			_linkType='VLAN'
			_linkMaster="$(grep "${_interface}" /proc/net/vlan/config | awk 'BEGIN {FS="|"}; {gsub(/ /, "", $3); print $3}')"
		fi

		#Get additional details from configuration file
		if [[ -f "${SYSCONFIG_NETWORK_SCRIPTS}/ifcfg-${_interface}" ]]; then
			unset BONDING_OPTS BOOTPROTO DEVICE IPADDR MASTER NETMASK PHYSDEV PREFIX SLAVE TYPE VLAN #Clear ifcfg-* variables

			source "${SYSCONFIG_NETWORK_SCRIPTS}/ifcfg-${_interface}"
			if [[ -n "${TYPE:-}" ]]; then
				case "${TYPE,,}" in
					'bond')
						_linkType='Bond'
						[[ -n "${BONDING_OPTS:-}" ]] && _linkMode="${BONDING_OPTS//=/-}"
						;;
					'ethernet') _linkType='Ethernet';;
				esac
			fi
			if [[ -n "${VLAN:-}" && "${VLAN,,}" == 'yes' ]]; then
				_linkType='VLAN'
				[[ "${_linkMaster}" == '--' ]] && _linkMaster="${PHYSDEV:-}"
				if [[ "${_linkMode}" == '--' ]]; then
					_linkMode="${DEVICE:-}"
					_linkMode="${_linkMode//vlan}"
					_linkMode="${_linkMode//${_linkMaster}}"
					_linkMode="${_linkMode//.}"
					[[ "${_linkMode}" =~ ^[[:digit:]]{1,4}$ ]] && _linkMode=$(( 10#${_linkMode} ))
				fi
			fi
			if [[ -n "${SLAVE:-}" && "${SLAVE,,}" == 'yes' ]]; then
				_linkType='Bond'
				_linkMode='Slave'
				_linkMaster="${MASTER:-}"
			fi
			if [[ -n "${BOOTPROTO:-}" ]]; then
				case "${BOOTPROTO,,}" in
					'dhcp') _linkAddressMode='DHCP';;
					'none'|'static')
						_linkAddressMode='Static'
						if [[ -z "${_runningIPAddress:-}" && -n "${IPADDR:-}" ]]; then
							_configuredIPAddress="${IPADDR}"
							if [[ -n "${NETMASK:-}" ]]; then
								_configuredIPAddress="${_configuredIPAddress}/$(__netmaskToBitmask "${NETMASK}")"
							elif [[ -n "${PREFIX:-}" ]]; then
								_configuredIPAddress="${_configuredIPAddress}/${PREFIX}"
							else
								_configuredIPAddress="${_configuredIPAddress}/$(__netmaskToBitmask "$(ipcalc -s -m "${_configuredIPAddress}" | awk 'BEGIN {FS="="}; {print $2};')")"
							fi
						fi
						;;
				esac
			fi
		fi

		#Get established link speed details
		case "${_linkState,,}" in
			'up') [[ "${_linkType,,}" != 'loopback' ]] && _linkSpeed="$(cat /sys/class/net/${_interface}/speed 2>/dev/null || :)";;
			'down'|'no-link')
				_linkSpeed=$(__trim "$(ethtool "${_interface}" 2>/dev/null | sed -nr -e "/Supported link modes/,/^\t\w/p" | tail -n 2 | head -n 1 | awk 'BEGIN {FS="/"}; {print $1};')")
				_linkSpeed="${_linkSpeed%%[[:alpha:]]*}"
				;;
		esac

		[[ -z "${_linkSpeed:-}" ]] && _linkSpeed='--'
		[[ "${_linkType}" == '--' ]] && _linkType='Ethernet'

		if [[ "${_linkSpeed}" != '--' ]]; then
			case ${#_linkSpeed} in
				[1-3]) _linkSpeed="${_linkSpeed} Mb/s";;
				[4-6]) _linkSpeed="$(( ${_linkSpeed} / 1000 )) Gb/s";;
				[7-9]) _linkSpeed="$(( ${_linkSpeed} / 1000000 )) Tb/s";;
			esac
		fi

		if [[ -n "${_runningIPAddress:-}" ]]; then
			IFS=$'\n'
			for _runningIPAddress in $(ip --oneline address show ${_interface:-} | awk 'match($3, /^inet6?$/) {print $4}'); do
				printf "${_outputFormat}" "${_interface:-}" "${_runningIPAddress:---}" "${_linkState:-}" "${_linkType:-}" "${_linkMode:-}" "${_linkMaster:-}" "${_linkSpeed:-}"
				_interface=' '
				unset _linkState _linkType _linkMode _linkMaster _linkSpeed
			done
			unset IFS
		else
			[[ "${_linkState,,}" == 'up' ]] && unset _configuredIPAddress
			printf "${_outputFormat}" "${_interface:-}" "${_runningIPAddress:-${_configuredIPAddress:---}}" "${_linkState:-}" "${_linkType:-}" "${_linkMode:-}" "${_linkMaster:-}" "${_linkSpeed:-}"
		fi

		if __isDebugEnabled; then
			__printMessage "    Interface:  ${_interface:-}" >&2
			__printMessage "    BOOTPROTO:  $(__printInterfaceConfigValue "${_interface}" 'BOOTPROTO')" >&2
			__printMessage "       MASTER:  $(__printInterfaceConfigValue "${_interface}" 'MASTER')" >&2
			__printMessage "       Status:  ${_status:-}" >&2
			__printMessage "   Running IP:  ${_runningIPAddress:-}" >&2
			__printMessage "  Link Master:  ${_linkMaster:-}" >&2
			__printMessage "    Link Mode:  ${_linkMode:-}" >&2
			__printMessage "   Link State:  ${_linkState:-}" >&2
			__printMessage "   Link Speed:  ${_linkSpeed:-}" >&2
			__printMessage "    Link Type:  ${_linkType:-}" >&2
			__printMessage "  Raw Details:  ${_details:-}" >&2
			__printMessage >&2
		fi

		_previousInterface="${_interface}"

		unset _linkAddressMode _linkMaster _linkMode _linkSpeed _linkState _linkType
		unset _details _interface _runningIPAddress _state _status
	done < <(join -a 1 -a 2 2>/dev/null <(ip --details --oneline link show | awk 'BEGIN {FS=": "} {gsub(/@.*$/, "", $2); print $2, $3}' | sort -u) <(ls -1 /etc/sysconfig/network-scripts/ifcfg-* 2>/dev/null | awk 'BEGIN {FS="-"}; {print $3, "<CFG-FILE>", "DOWN"};' | sort -u || :) | sort -u)
}

#__printMessage()
	#Prints an empty line
	#Return Codes:	0

#__printMessage(Message, Newline=${true}, MinimumDebugLevel=0)
	#Prints out ${Message} and adds a linefeed if ${Newline} is true
		#If MinimumDebugLevel is higher than DEBUG, the message will not be printed
	#Return Codes:	0
	#Exit Codes:	1=Invalid parameter count
function __printMessage() {
	[[ ${#} -gt 3 ]] && __raiseWrongParametersError ${#} 0 3

	local -i _minimumDebugLevel="${3:-0}"

	case ${#} in
		0) [[ ${DEBUG} -ge ${_minimumDebugLevel} ]] && printf '%b\n' "${RST}" ;;
		1|2|3)
			local -a _caller=($(caller 0))
			local _message="${RST}${1:-}${RST}"
			local -i _newline=${2:-${true}}

			[[ ${LOG_DEBUG} -eq ${true} || ${DEBUG} -ge ${_minimumDebugLevel} ]] && __logMessage "${_message}"
			if [[ ${DEBUG} -ge ${_minimumDebugLevel} ]]; then
				[[ ${_minimumDebugLevel} -gt 0 ]] && _message="${RST}${IYELLOW}DEBUG :: $(__getFileName "${_caller[2]}")|${_caller[1]}|${_caller[0]}|${_minimumDebugLevel} :: ${RST}${_message}"
				printf "%b" "${_message}"
				(( _newline )) && printf "\n"
			fi
			;;
		*) __raiseWrongParametersError ${#} 0 3 ;;
	esac

	return 0
}

#__printStackTrace()
	#Prints out function call tree
	#Return Codes:	0=Success
function __printStackTrace() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	local -a _caller
	local -i _frame=0
	local IFS

	__printMessage "${IWHITE}Begin Call Trace"
	while _caller=($(caller ${_frame})); do
		(( ++_frame ));
		__printMessage "	Call Trace (${_frame}): Line ${_caller[0]} in ${_caller[2]}::${_caller[1]}"
	done
	__printMessage "${IWHITE}End Call Trace"

}

#__printStatusMessage(Row, Column, Message, ClearToEnd=${false}, ReturnCursor=${true})
	#Prints Message starting at Row and Column position
		#If ClearToEnd is true then it clears everything from the point of Row and Column down
		#If ReturnCursor is true then it moves the cursor back to the previous cursor position
			#If ClearToEnd is ${true}, ReturnCursor will always be ${false}
	#Return Codes:	0
	#Exit Codes:	1=Wrong Parameters; 2=Invalid Parameter
function __printStatusMessage() {
	[[ ${#} -lt 3 || ${#} -gt 5 ]] && __raiseWrongParametersError ${#} 3 5
	local IFS
	local -i _clearToEnd=${4:-${false}}
	local -i _column=${2:?$(__raiseError 'Column is required')}
	local -a _cursorPosition=($(__getCursorPosition))
	local -i _fd
	local _message="${3:?$(__raiseError 'Message is required')}"
	local -i _row=${1:?$(__raiseError 'Row is required')}
	local -i _returnCursor="${5:-${true}}"

	(( _clearToEnd )) && _returnCursor=${false}

	exec {_fd}<"$(__getDirectoryName)/$(__getFileName)"
	while :; do
		if flock --exclusive --nonblock ${_fd}; then
			if [[ $(tput lines) -eq $((${_cursorPosition[0]} + 1)) ]]; then
				__printMessage "${_message}"
			else
				__setCursorPosition ${_row} ${_column} ${_clearToEnd}
				tput el || :
				__printMessage "${_message}" ${false}
				(( _returnCursor )) && __setCursorPosition ${_cursorPosition[*]}
			fi
			flock --unlock ${_fd}
			break
		else
			__logMessage "Waiting for lock (${_column},${_row}): ${_message}"
			__sleepPseudoRandom
		fi
	done
	exec {_fd}>&-

	return 0
}

#__printTitle(Title, Subtitle="", DisplayBreadcrumbs=${true})
	#Prints title underlined
		#If Subtitle is supplied, it is printed indented below the title
		#If DisplayBreadcrumbs is true, then print out breadcrumb trail
	#Return Codes:	0
function __printTitle() {
	[[ ${#} -lt 1 || ${#} -gt 3 ]] && __raiseWrongParametersError ${#} 1 3
	local _crumb
	local -i _displayBreadcrumbs=${3:-${true}}
	local _subtitle="${2:-}"
	local _title="${GREEN}${UNDR}"

	__clearScreen
	if (( _displayBreadcrumbs )); then
		for _crumb in "${BREADCRUMBS[@]}"; do
			if [[ -n "${_crumb}" && "${1}" != "${_crumb}" ]]; then
				_title+="${_crumb}${RST}${IWHITE} » ${RST}${GREEN}${UNDR}"
			fi
		done
	fi
	__printMessage "${_title}${IGREEN}${UNDR}${1:?$(__raiseError 'Title is required')}"
	__isColorsLoaded || {
		printf -v line '%*s' $(__removeEscapeCodes "${_title}${1}" | wc -m)
		printf '%s\n' "${line// /-}"
	}
	[[ -n "${_subtitle// /}" ]] && __printMessage "  ${_subtitle}"
	__printMessage

	return 0
}

#__raiseError(Message="Unhandled Error", ExitCode=255)
	#Prints ${Message}
	#Return Codes:
	#Exit Codes:	255=Unhandled Error
function __raiseError() {
	[[ ${#} -gt 2 ]] && __raiseWrongParametersError ${#} 0 2
	local -i _exitCode=${2:-255}
	local _message="${1:-'Unhandled Error'}"

	__printErrorMessage "${_message}" >&2
	printf '\r'
	tput ed
	__isDebugEnabled && __printStackTrace >&2
	exit ${_exitCode}
}

#__raiseWrongParametersError(Received, MinimumExpected, MaximumExpected)
	#Raises an error about receiving the wrong number of parameters for a function
	#Exit Codes:	254=Wrong Parameter Count
function __raiseWrongParametersError() {
	case ${#} in
		2)
			__printErrorMessage "Wrong number of parameters received by function ${FUNCNAME[1]}. (Received: ${1}; Expected: ${2})"
			;;
		3)
			__printErrorMessage "Wrong number of parameters received by function ${FUNCNAME[1]}. (Received: ${1}; Expected: ${2}-${3})"
			;;
		*)
			__raiseWrongParametersError ${#} 2 3
			;;
	esac
	__printStackTrace
	__printMessage
	__printFunctionUsage 254 '' "${BASH_SOURCE[1]}" "${FUNCNAME[1]}"
}

#__reboot()
	#Reboots the machine
	#Return Codes:
	#Exit Codes:	0
function __reboot() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	__printMessage "Rebooting ..."
	$(sleep 1 && reboot) &

	exit 0
}

#__removeBreadcrumb(Crumb)
	#Removes Crumb from BREADCRUMBS array used by __printTitle
	#Return Codes:	0
function __removeBreadcrumb() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _crumb="${1:?$(__raiseError 'Crumb is required')}"
	local -i _index

	for _index in "${!BREADCRUMBS[@]}"; do
		[[ "${BREADCRUMBS[${_index}],,}" == "${_crumb,,}" ]] && unset BREADCRUMBS[${_index}]
	done
	[[ ${#BREADCRUMBS[@]} -gt 0 ]] && BREADCRUMBS=("${BREADCRUMBS[@]}") #Clear out empty elements

	return 0
}

#__removeEscapeCodes(String)
	#Removes escape codes from the string
	#Return Codes:	0
function __removeEscapeCodes() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1

	printf '%s' "${1:-}" | sed -r 's~\x01?(\x1B\(B)?\x1B\[([0-9;]*)?[JKmsu]\x02?~~g'

	return 0
}

#__removeDirectory(DirectoryName, Force=${false})
	#Removes DirectoryName if empty
		#If Force is true, will remove directory and contents
	#Return Codes:	0=Success; 1=Failed
function __removeDirectory() {
	[[ ${#} -lt 1 || ${#} -gt 2 ]] && __raiseWrongParametersError ${#} 1 2
	local _directoryName="${1:?$(__raiseError 'DirectoryName is required')}"
	local _force="${2:-${false}}"

	if [[ -d "${_directoryName}" ]]; then
		__printMessage "Removing Directory '${IWHITE}${_directoryName}${RST}' ... " ${false}
		if (( _force )) && rm -rf "${_directoryName}" 2>/dev/null; then
			__printMessage "${IGREEN}Done"
		elif ! (( _force )) && rmdir "${_directoryName}" 2>/dev/null; then
			__printMessage "${IGREEN}Done"
		else
			__printMessage "${IRED}Failed"
			return 1
		fi
	fi

	return 0
}

#__removeFile(FileName)
	#Removes FileName
	#Return Codes:	0=Success; 1=Failed
function __removeFile() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _file
	local _fileName="${1:?$(__raiseError 'FileName is required')}"
	local IFS

	if [[ "${_fileName}" != "${_fileName//\*/}" ]]; then
		__printDebugMessage "Resolving Wildcards: '${_fileName}'"
		for _file in $(ls -1 ${_fileName} 2>/dev/null); do
			__removeFile "${_file}" || :
		done
		__printDebugMessage "Done With Wildcards"
	elif [[ -f "${_fileName}" ]]; then
		__printMessage "Removing File '${IWHITE}${_fileName}${RST}' ... " ${false}
		if rm -f "${_fileName}"; then
			__printMessage "${IGREEN}Done"
		else
			__printMessage "${IRED}Failed"
			return 1
		fi
	fi

	return 0
}

#__rescanDisks()
function __rescanDisks() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	if [[ -d "/sys/class/scsi_host/" ]]; then
		__printMessage "${IWHITE}Rescanning for new disks ... " ${false}; _cursorPosition=($(__getCursorPosition)); __printMessage

		for _adapter in /sys/class/scsi_host/host*; do
			echo '- - -' > "${_adapter}/scan" 2> /dev/null
		done

		__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done"
	fi
}

#__restartNetworkInterface(Interface)
	#Stops and starts Interface
function __restartNetworkInterface() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _interface="${1:?$(__raiseError 'Interface is required')}"

	__stopNetworkInterface "${_interface}" || :
	ip addr flush dev "${_interface}" || :
	__sleepPseudoRandom
	__startNetworkInterface "${_interface}" || :

	return 0
}

#__setClearScreenState(State=[0|1])
	#Changes the suppression of screen clearing
	#	State: 0=Enabled; 1=Disabled
	#Return Codes:	0
	#Exit Codes:	1=Invalid parameter count
function __setClearScreenState() {
	#Dependencies:  __raiseError, __raiseWrongParametersError
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local -i _state=${1:?$(__raiseError 'State is required to be 0=Enabled or 1=Disabled')}

	case ${_state} in
		0|1) SUPPRESS_CLEAR=${_state} ;;
		*) __raiseError 'State must be 0=Enabled or 1=Disabled' ;;
	esac

	return 0
}

#__setCursorMovement(State=[0|1])
	#Changes the suppression of cursor movement
	#	State: 0=Enabled; 1=Disabled
	#Return Codes:	0
	#Exit Codes:	1=Invalid parameter count
function __setCursorMovement() {
	#Dependencies:  __raiseError, __raiseWrongParametersError
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local -i _state=${1:?$(__raiseError 'State is required to be 0=Enabled or 1=Disabled')}

	case ${_state} in
		0|1) SUPPRESS_CURSOR_MOVEMENT=${_state} ;;
		*) __raiseError 'State must be 0=Enabled or 1=Disabled' ;;
	esac

	return 0
}

#__setCursorPosition(Row=0, Column=0, ClearToEnd=${false})
	#Sets the cursor position to Row and Column
	#Return Codes:	0
function __setCursorPosition() {
	#Dependencies:  __getCursorPosition, __isDebugEnabled, __printMessage, __raiseWrongParametersError
	[[ ${#} -gt 3 ]] && __raiseWrongParametersError ${#} 0 3
	local -i _clearToEnd=${3:-${false}}
	local -i _column=${2:-0}
	local -i _fd
	local IFS
	local -i _row=${1:-0}

	[[ ${_column} -lt 0 ]] && _column=0
	[[ ${_row} -lt 0 ]] && _row=0

	if __isDebugEnabled; then
		local -a _position=($(__getCursorPosition))
		[[ ${_position[1]} -ne 0 ]] && __printMessage
		__printMessage "${IRED}${ONBLUE}	---> Cursor Movement From: (${_position[0]},${_position[1]}); To: (${_row},${_column}) <---${RST}"
	elif (( SUPPRESS_CURSOR_MOVEMENT )); then
		:
	else
		tput cup ${_row} ${_column}
		sleep 0.01
		(( _clearToEnd )) && {
			tput ed #Clear to end of screen
			tput sgr0 #Reset text output
		}
	fi

	return 0
}

#__setEchoState(State=[0|1])
	#Changes the input echo state
		#State: 0=Hidden; 1=Displayed
	#Return Codes:	0
	#Exit Codes:	254=Invalid parameter count
function __setEchoState() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local -i _state="${1:?$(__raiseError 'State is required to be 0=Hidden or 1=Displayed')}"

	case ${_state} in
		0)
			stty -echo 2>/dev/null || :;;
		1)
			stty echo 2>/dev/null || :;;
		*)
			__raiseError "State must be 0=Hidden or 1=Displayed";;
	esac

	return 0
}

#__sleepPseudoRandom()
	#Sleeps for a pseudorandom period of time between 0.001-0.999 seconds
function __sleepPseudoRandom() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	sleep "0.$(printf '%03d' "$(((${RANDOM} % 998) + 1))")"
}

#__startNetworkInterface(Interface)
	#Starts Interface
	#Return Codes:	0=Success; 1=Failed
function __startNetworkInterface() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _interface="${1:?$(__raiseError 'Interface is required')}"
	local -a _cursorPosition

	__printMessage "Starting ${_interface} ... " ${false}; _cursorPosition=($(__getCursorPosition)); __printMessage
	if ifup "${_interface}"; then
		__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done" ${true}
	else
		__printStatusMessage ${_cursorPosition[*]} "${IRED}Failed"
		return 1
	fi

	return 0
}

#__stopNetworkInterface(Interface)
	#Starts Interface
	#Return Codes:	0=Success; 1=Failed
function __stopNetworkInterface() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _interface="${1:?$(__raiseError 'Interface is required')}"
	local -a _cursorPosition

	__printMessage "Stopping ${_interface} ... " ${false}; _cursorPosition=($(__getCursorPosition)); __printMessage

	#Remove dead dhclient/dhclient6 pid files, these files will cause ifdown to fail when they exist and the process isn't running
	[[ -f "/var/run/dhclient-${_interface}.pid" ]] && [[ ! -e "/proc/$(cat /var/run/dhclient-${_interface}.pid)" ]] && __removeFile "/var/run/dhclient-${_interface}.pid" >/dev/null 2>&1 || :
	[[ -f "/var/run/dhclient6-${_interface}.pid" ]] && [[ ! -e "/proc/$(cat /var/run/dhclient6-${_interface}.pid)" ]] && __removeFile "/var/run/dhclient6-${_interface}.pid" >/dev/null 2>&1 || :

	if ifdown "${_interface}"; then
		__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done" ${true}
	else
		__printStatusMessage ${_cursorPosition[*]} "${IRED}Failed (${?})"
		return 1
	fi

	return 0
}

#__toggleBoolean(BooleanVariableName)
	#Toggles a boolean variable between true and false
	#Return Codes:	0
	#Exit Codes:	1=Invalid parameter count
function __toggleBoolean() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1

	(( ${!1} )) && eval ${1}=${false} || eval ${1}=${true}

	return 0
}

#__trapCtrlC()
	#Captures the Ctrl+C keypress event when enabled by adding 'trap __trapCtrlC SIGINT' to the script
	#Prompts if you are sure you want to exit the script
	#Return Codes:	0=Ctrl+C was cancelled
	#Exit Codes:	130=Ctrl+C was pressed and exit was confirmed
function __trapCtrlC() {
	local -i _echoState=$(__getEchoState)
	local -a _position=($(__getCursorPosition))

	if [[ ${_echoState} -eq 1 ]]; then #Remove the ^C output
		tput cub 2 || printf '\b\b  \b\b'
		tput el
	fi
	[[ ${_position[1]:0} -ne 2 ]] && __printMessage
	if __getYesNoInput "Exit $(__getFileName)?"; then
		exit 130 #Standard Ctrl+C exit code
	else
		EXIT_CANCELLED=${true}
		__setEchoState ${_echoState}
		__printMessage "${IWHITE}Press Enter to resume ..." ${false}
		return 0
	fi
}

#__trapCtrlZ()
	#Captures the Ctrl+Z keypress event when enabled by adding 'trap __trapCtrlZ SIGTSTP' to the script
	#Toggles Debugging on and off
	#Return Codes:	0
function __trapCtrlZ() {
	local -a _position=($(__getCursorPosition))

	if [[ ${_echoState} -eq 1 ]]; then #Remove the ^Z output
		tput cub 2 || printf '\b\b  \b\b'
		tput el
	fi
	[[ ${_position[1]:0} -ne 2 ]] && __printMessage
	__toggleBoolean 'DEBUG'
	(( DEBUG )) && __printMessage "${IWHITE}Debugging ${IGREEN}Enabled" || __printMessage "${IWHITE}Debugging ${IYELLOW}Disabled"
	EXIT_CANCELLED=${true}
	__printMessage "${IWHITE}Press Enter to resume ..." ${false}

	return 0
}

#__trapExit()
	#Ensures prompt is put back to normal
	#Enable this function by adding 'trap __trapExit EXIT' to the script
	#Return Codes:	<none>
	#Exit Codes:	<none>
function __trapExit() {
	__printMessage #Move to a new line
	__setEchoState 1 #Ensure typed characters are echoed
}

#__trim(String)
	#Removes leading and trailing spaces
function __trim() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	[[ ${#1} -eq 0 ]] && return 0
	local _string="${1:?$(__raiseError 'String is required')}"

	_string="${_string#"${_string%%[![:space:]]*}"}"
	_string="${_string%"${_string##*[![:space:]]}"}"

	printf '%b' "${_string}"
}

#__uninstallPackage(PackageName)
	#Uninstalls the specified packageName
	#Return Codes:  0=success/not installed, 1=failure
function __uninstallPackage() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _packageName="${1:?$(__raiseError 'PackageName is required')}"
	local _package

	#Need to check each package individually as some might be installed and others not
	__printMessage "${IWHITE}Checking if package(s) are installed"
	for _package in $(awk '{for (i = 1; i <= NF; ++i) print $i};' <<< "${_packageName}"); do
	__printMessage "\tChecking Package:  ${IWHITE}${_package}${RST} ... " ${false}
		if __checkInstalledPackage "${_package}"; then
			__printMessage "${IGREEN}Installed"
		else
			__printMessage "${IRED}Not Installed"
			_packageName="${_packageName//${_package}/}" #Strip out packages that are installed from the list
		fi
	done
	_packageName="${_packageName//  / }"

	if [[ -n "${_packageName// /}" ]]; then
		__printMessage "Removing ${IWHITE}${_packageName}${RST} ..." ${false}

		if yum erase -y -q "${_packageName}" 2>/dev/null; then
			__printMessage " ${IGREEN}Done!"
		else
			__printMessage " ${IRED}Failed!"
			return 1
		fi
	fi

	return 0
}

#__unloadColors()
	#Sets all of the color variables to empty strings
	#Return Codes:	0
function __unloadColors() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0
	tput sgr0 #Reset terminal

	BOLD=""
	BOLD_STOP=""
	UNDR=""
	UNDR_STOP=""
	INV=""
	RST=""
	BLACK=""
	IBLACK=""
	ONBLACK=""
	RED=""
	IRED=""
	ONRED=""
	GREEN=""
	IGREEN=""
	ONGREEN=""
	YELLOW=""
	IYELLOW=""
	ONYELLOW=""
	BLUE=""
	IBLUE=""
	ONBLUE=""
	PURPLE=""
	IPURPLE=""
	ONPURPLE=""
	CYAN=""
	ICYAN=""
	ONCYAN=""
	WHITE=""
	IWHITE=""
	ONWHITE=""

	return 0
}

#__zeroDisk(Disk)
	#Removes all existing partition data
	#Return Codes:	0=Success; 1=Invalid Disk; 2=Failed to zero disk
function __zeroDisk() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _disk="/dev/${1:?$(__raiseError 'Disk is required')}"; _disk="${_disk//\/\///}"; _disk="${_disk//\/dev\/dev\///dev/}"

	[[ ! -b "${_disk}" ]] && return 1

	__printMessage "Zeroing Disk ${_disk} ... " ${false}
	if sgdisk -Z "${_disk}" >/dev/null 2>&1; then
		__printMessage "${IGREEN}Done"
		return 0
	else
		__printMessage "${IRED}Failed"
		return 2
	fi
}

#These declares statements are to ensure global scope for the colors
declare	BOLD BOLD_STOP UNDR UNDR_STOP INV RST
declare BLACK IBLACK ONBLACK RED IRED ONRED GREEN IGREEN ONGREEN YELLOW IYELLOW ONYELLOW BLUE IBLUE ONBLUE PURPLE IPURPLE ONPURPLE CYAN ICYAN ONCYAN WHITE IWHITE ONWHITE
__unloadColors #Make sure the values are all empty strings

### END: Function Declarations ###
### ########################## ###

### system_setup specific code ###
### ########################## ###

#Update persisted variables
declare -i ss_AUTO_UPDATE=${false}
declare ss_SSH_KEY_FILE='%STAGING_DIRECTORY%/cloudian-installation-key'
declare ss_STAGING_DIRECTORY='/root/CloudianPackages'
declare ss_SURVEY_FILE='%STAGING_DIRECTORY%/survey.csv'
declare -i ss_USE_COLORS=${true}
declare ss_FSTYPE='ext4'
declare ss_DISK_MOUNTPATH='/cloudian'

#Non-update persisted variables
declare -i ss_REBOOT=${false}
declare -i ss_UPDATED=${false}
declare ss_REMOTE=${false}
declare ss_uri='https://www.cloudian.info/pydio/public/system-setup/dl/system_setup.sh'
declare ss_uri_beta='https://www.cloudian.info/pydio/public/system-setup2/dl/system_setup2.sh'
declare ss_versionsURL='https://www.cloudian.info/pydio/public/versions/dl/versions.txt'

declare -a RESTRICTED_PASSWORDS=('password' 'assword' 'cloudian' 'drowssap' 'p@ssw0rd') #Restricted password options
declare -a REQUIRED_PACKAGES=('bc' 'bind-utils' 'dmidecode' 'facter' 'gdisk' 'nc' 'ntp' 'ntpdate' 'openssh' 'pax' 'pciutils' 'sshpass' 'unzip' 'wget')
declare -a OPTIONAL_PACKAGES=('bash-completion' 'nano' 'parted' 's3cmd' 'sg3_utils')

#Networking Constants
declare HOSTS_FILE="/etc/hosts"
declare RESOLV_CONF="/etc/resolv.conf"
declare SYSCONFIG_NETWORK="/etc/sysconfig/network"
declare SYSCONFIG_NETWORK_SCRIPTS="/etc/sysconfig/network-scripts"
declare SYSCTL_CONF="/etc/sysctl.conf"
declare -i ss_RESTART_NETWORKING=${false}

#Date & Time Constants
declare CLOCKFILE="/etc/sysconfig/clock"
declare TZ_DIR="/usr/share/zoneinfo"
declare TZ_COUNTRY_TABLE="${TZ_DIR}/iso3166.tab"
declare TZ_LOCALTIME="/etc/localtime"
declare TZ_ZONE_TABLE="${TZ_DIR}/zone.tab"

#preInstallCheck non update persisted variables
declare -i pic_CREATE_LOG=${false}
declare -i pic_FORCE_SYNC_NTP=${false}
declare -i pic_QUIET_MODE=${false}
declare -i pic_SKIP_NETWORK_CHECKS=${false}
declare -i pic_ZOMBIE_MODE=${false}

#Disk Configuration Variables
declare ss_FSLIST='/root/CloudianTools/fslist.txt'
declare -A ss_mountOptions=(
	['ext4']='defaults,rw,nosuid,noexec,nodev,noatime,data=ordered,errors=remount-ro'
	['xfs']='defaults,rw,nosuid,noexec,nodev,noatime'
)

#Survey File Regular Expressions
declare -r ss_datacenterRegEx='^[[:alpha:]]([[:alnum:]]|\-){0,255}$'
declare -r ss_hostnameRegEx="^([[:alnum:]]|\-|\_){1,${MAX_HOSTNAME_LENGTH}}(\..{2,63})*$"
declare -r ss_interfaceRegEx='^[[:alpha:]][[:alnum:]]*((\_|\.|\:)[[:digit:]]+)?$'
declare -r ss_rackRegEx="${ss_datacenterRegEx}"
declare -r ss_regionRegEx='^#?[[:alnum:]]([[:alnum:]]|\-){0,51}$'

declare ss_SURVEY_DISABLED_REGEX="^\#?${ss_regionRegEx:3:$((${#ss_regionRegEx} - 4))},${ss_hostnameRegEx:1:$((${#ss_hostnameRegEx} - 2))},${REGEX_IPADDRESS:1:$((${#REGEX_IPADDRESS} - 2))},${ss_datacenterRegEx:1:$((${#ss_datacenterRegEx} - 2))},${ss_regionRegEx:1:$((${#ss_regionRegEx} - 2))}(,(${ss_interfaceRegEx:1:$((${#ss_interfaceRegEx} - 2))})?)?$"
declare ss_SURVEY_ENABLED_REGEX="^${ss_SURVEY_DISABLED_REGEX:4}"
declare ss_SURVEY_INVALID_REGEX="(^#.*$|${ss_SURVEY_ENABLED_REGEX})"


#ss__addSurveyFileEntry(SurveyFile, Region, Hostname, IPAddress, Datacenter, Rack, Interface='')
	#Adds and entry to SurveyFile after confirming entry isn't already in the file.
function ss__addSurveyFileEntry() {
	[[ ${#} -lt 6 || ${#} -gt 7 ]] && __raiseWrongParametersError ${#} 6 7
	local _datacenter="${5:?$(__raiseError 'Datacenter is required')}"
	local _hostname="${3:?$(__raiseError 'Hostname is required')}"
	local _interface="${7:-}"
	local _ipAddress="${4:?$(__raiseError 'IPAddress is required')}"
	local _rack="${6:?$(__raiseError 'Rack is required')}"
	local _region="${2:?$(__raiseError 'Region is required')}"
	local _surveyFile="${1:?$(__raiseError 'SurveyFile is required')}"

	#Validate variables have valid inputs
	[[ -d "$(__getDirectoryName "${_surveyFile}")" ]] || __raiseError "$(__getDirectoryName "${_surveyFile}") directory not found for SurveyFile"
	[[ "${_region}" =~ ${ss_regionRegEx} ]] || __raiseError "Region '${_region}' is invalid"
	[[ "${_hostname}" =~ ${ss_hostnameRegEx} ]] || __raiseError "Hostname '${_hostname}' is invalid"
	[[ "${_ipAddress}" =~ ${REGEX_IPADDRESS} ]] || __raiseError "IPAddress '${_ipAddress}' is invalid"
	[[ "${_datacenter}" =~ ${ss_datacenterRegEx} ]] || __raiseError "Datacenter '${_datacenter}' is invalid"
	[[ "${_rack}" =~ ${ss_rackRegEx} ]] || __raiseError "Rack '${_rack}' is invalid"
	[[ -z "${_interface}" || ( -n "${_interface}" && "${_interface}" =~ ${ss_interfaceRegEx} ) ]] || __raiseError "Interface '${_interface}' is invalid"
	__printDebugMessage 'All Inputs are valid, need to check if it is already in the survey file now'

	[[ -n "${_interface}" ]] && _interface=",${_interface}"
	if [[ -f "${_surveyFile}" ]] && grep -q -i "${_region},${_hostname},${_ipAddress},${_datacenter},${_rack}${_interface}" "${_surveyFile}"; then
		__printErrorMessage 'Duplicate Entry Found'
		__printDebugMessage "$(grep -i "${_region},${_hostname},${_ipAddress},${_datacenter},${_rack}${_interface}" "${_surveyFile}")"
	else
		__printMessage "Adding entry to ${_surveyFile} ... " ${false}
		printf '%s\n' "${_region,,},${_hostname},${_ipAddress},${_datacenter},${_rack}${_interface}" >> "${_surveyFile}"
		__printMessage "${IGREEN}Done"
	fi

	return 0
}

#ss__changePassword()
	#Change password for running user on local or survey file nodes
	#Return Codes:	0=Success; 1=Failed; 2=Cancelled
function ss__changePassword() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0
	local _clusterPassword
	local -i _clusterUpdate=${false}
	local -i _exitCode
	local _password1 _password2
	local -i _restrictedCount=0
	local _sshCommand

	if grep -q -E "${ss_SURVEY_ENABLED_REGEX}" "$(ss__getSurveyFileName)" 2>/dev/null; then
		__getYesNoInput 'Would you like to update your password on all nodes listed in your survey file?' 'Yes' && _clusterUpdate=${true}
		__printMessage
	fi

	while (( ${true} )); do
		while [[ ${_restrictedCount} -le ${INPUT_LIMIT} ]]; do
			__getInput 'New Password: ' '_password1' '' ${true} '.+' || return 1
			if [[ "${_password1,,}" =~ ^($(IFS='|'; echo "${RESTRICTED_PASSWORDS[*]}"; unset IFS))$ ]]; then
				(( ++_restrictedCount ))
				__printErrorMessage "Password is too simple. Please try again. (Attempt ${_restrictedCount} of ${INPUT_LIMIT})"
			else
				_restrictedCount=0
				break
			fi
		done
		(( _restrictedCount )) && return 2
		__getInput 'Retype New Password: ' '_password2' '' ${true} '.+' || return 1
		__printMessage

		[[ "${_password1}" == "${_password2}" ]] && break

		__printErrorMessage 'Passwords do not match'
		__getYesNoInput 'Would you like to try again?' 'Yes' || return 2
	done

	if (( _clusterUpdate )); then
		if ! [[ -f "$(ss__getSSHKeyFileName)" ]]; then
			__logMessage 'No SSH Key File'
			__printMessage "If your ${USER} password is the same on all (or most) nodes in the cluster, you can supply it as a cluster password"
			__printMessage 'If you do not want to supply a password, each server will prompt for one when connecting.'
			__printMessage
			__getInput 'Cluster Password:' '_clusterPassword' '' ${true} || break
		fi

		_sshCommand=$(ss__printInstallSSHKeyFileCommand "$(ss__getSSHKeyFileName)" ${true}) #Silently install the SSH Key File

		_sshCommand+=$(cat <<-EOF
			if echo "\${USER}:${_password1}" | chpasswd; then
				echo "Successfully changed \${USER} password on \$(hostname -s)."
			else
				echo "Failed (${?})"
				exit 190
			fi
			EOF
		)

		ss__runOnCluster "${_sshCommand}" "${_clusterPassword:-}" ${true} || _exitCode=${?}
	else
		printf '%s' "${USER}:${_password1}" | chpasswd || _exitCode=${?}
	fi

	return ${_exitCode:-0}
}

#ss__changeSSHKeyFileLocation()
	#Prompts and changes the SSH Key file location
	#Return Codes:	0
	#Exit Codes:	1=Wrong parameter count
function ss__changeSSHKeyFileLocation() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0
	local -a _cursorPosition
	local _input

	__printTitle 'SSH Key File Location' "Location: $(ss__getSSHKeyFileName)"
	_cursorPosition=($(__getCursorPosition))
	while __getInput 'New SSH key file location:' '_input' "$(ss__getSSHKeyFileName)" ${false} '.+'; do
		_input="${_input/#\~/${HOME}}"
		if [[ -d "${_input}" ]]; then
			_input+="/$(__getFileName "$(ss__getSSHKeyFileName)")"
			break
		elif [[ -d "$(dirname "${_input}")" ]]; then
			break
		elif __getYesNoInput "${IRED}Directory $(dirname "${_input}") does not exist.${RST}\nWould you like to create it?"; then
			mkdir -p "$(dirname "${_input}")"
			break
		elif ! __getYesNoInput 'Would you like to retype your entry?'; then
			break
		fi
		__setCursorPosition ${_cursorPosition[*]} ${true}
	done

	if [[ "$(ss__getSSHKeyFileName)" != "${_input}" ]]; then
		if [[ -f "$(ss__getSSHKeyFileName)" && -d "$(dirname "${_input}")" ]]; then
			if __getYesNoInput 'Move your existing SSH key file to the new location?'; then
				__printMessage
				__printMessage "${IWHITE}Moving SSH key file ... " ${false}
				if mv "$(ss__getSSHKeyFileName)" "${_input}"; then
					__printMessage "${IGREEN}Done"
				else
					__printMessage "${IRED}Failed"
					__raiseError
				fi
			fi
		fi

		__printMessage
		__printMessage "${IWHITE}Saving settings ... " ${false}

		ss_SSH_KEY_FILE="${_input//${ss_STAGING_DIRECTORY}\//%STAGING_DIRECTORY%/}"
		ss_SSH_KEY_FILE="${ss_SSH_KEY_FILE//\/\///}"
		ss__saveSetting 'ss_SSH_KEY_FILE'

		__printMessage "${IGREEN}Done"
	else
		__printMessage
		__printMessage 'SSH Key file location was not changed'
	fi
	__printMessage
	__pause

	return 0
}

#ss__changeStagingDirectory()
	#Prompts and changes the Staging Directory location
	#Return Codes:	0
	#Exit Codes:	1=Wrong parameter count
function ss__changeStagingDirectory() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0
	local -a _cursorPosition
	local _input

	__printTitle 'Staging Directory' "Location: ${IWHITE}${ss_STAGING_DIRECTORY}"
	_cursorPosition=($(__getCursorPosition))
	while __getInput 'Staging Directory:' '_input' "${ss_STAGING_DIRECTORY}" ${false} '.+'; do
		_input="${_input/#\~/${HOME}}"
		if [[ -d "${_input}" ]]; then
			_input="$(dirname "${_input}/null")"
			break
		elif __getYesNoInput 'Would you like to create this directory?'; then
			_input="$(dirname "${_input}/null")"
			mkdir -p "${_input}"
			break
		elif ! __getYesNoInput 'Would you like to retype your entry?'; then
			break
		fi
		__setCursorPosition ${_cursorPosition[*]} ${true}
	done

	if [[ -d "${_input}" && "${_input}" != "${ss_STAGING_DIRECTORY}" ]]; then
		if [[ -d "${ss_STAGING_DIRECTORY}" ]]; then
			if find "${ss_STAGING_DIRECTORY}" -mindepth 1 -print -quit | grep -q .; then
				__printMessage
				if __getYesNoInput 'Move everything from your old staging directory to the new location?'; then
					__printMessage
					__printMessage "${IWHITE}Moving contents ... " ${false}
					if mv -f "${ss_STAGING_DIRECTORY}"/* "${_input}"/; then
						__printMessage "${IGREEN}Done"
					else
						__printMessage "${IRED}Failed"
						__raiseError
					fi
					rmdir "${ss_STAGING_DIRECTORY}"
				else #Statically set variables if using %STAGING_DIRECTORY% since we didn't move files
					ss_SURVEY_FILE="$(ss__getSurveyFileName)"
					ss_SSH_KEY_FILE="$(ss__getSSHKeyFileName)"
				fi
			else
				__removeDirectory "${ss_STAGING_DIRECTORY}"
			fi
		fi

		__printMessage
		__printMessage "${IWHITE}Saving settings ... " ${false}

		ss_SURVEY_FILE="${ss_SURVEY_FILE//${_input}\//%STAGING_DIRECTORY%/}"
		ss_SURVEY_FILE="${ss_SURVEY_FILE//\/\///}"
		ss__saveSetting 'ss_SURVEY_FILE'

		ss_SSH_KEY_FILE="${ss_SSH_KEY_FILE//${_input}\//%STAGING_DIRECTORY%/}"
		ss_SSH_KEY_FILE="${ss_SSH_KEY_FILE//\/\///}"
		ss__saveSetting 'ss_SSH_KEY_FILE'

		ss_STAGING_DIRECTORY="${_input//\/\///}"
		ss__saveSetting 'ss_STAGING_DIRECTORY'
		__printMessage "${IGREEN}Done"

		__printMessage
	else
		__printMessage
		__printMessage 'Staging Directory location was not changed'
	fi
	__printMessage
	__pause

	return 0
}

#ss__changeSurveyFileLocation()
	#Prompts and changes the Survey file location
	#Return Codes:	0
	#Exit Codes:	1=Wrong parameter count
function ss__changeSurveyFileLocation() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0
	local -a _cursorPosition
	local _input

	__printTitle 'Survey File Location' "Location: $(ss__getSurveyFileName)"
	_cursorPosition=($(__getCursorPosition))
	while __getInput 'New survey file location:' '_input' "$(ss__getSurveyFileName)" ${false} '.+'; do
		_input="${_input/#\~/${HOME}}"
		if [[ -d "${_input}" ]]; then
			_input+="/$(__getFileName "$(ss__getSurveyFileName)")"
			break
		elif [[ -d "$(dirname "${_input}")" ]]; then
			break
		elif __getYesNoInput "${IRED}Directory $(dirname "${_input}") does not exist.${RST}\nWould you like to create it?"; then
			mkdir -p "$(dirname "${_input}")"
			break
		elif ! __getYesNoInput 'Would you like to retype your entry?'; then
			break
		fi
		__setCursorPosition ${_cursorPosition[*]} ${true}
	done

	if [[ "$(ss__getSurveyFileName)" != "${_input}" ]]; then
		if [[ -f "$(ss__getSurveyFileName)" && -d "$(dirname "${_input}")" ]]; then
			if __getYesNoInput 'Move your existing survey file to the new location?'; then
				__printMessage
				__printMessage "${IWHITE}Moving survey file ... " ${false}
				if mv "$(ss__getSurveyFileName)" "${_input}"; then
					__printMessage "${IGREEN}Done"
				else
					__printMessage "${IRED}Failed"
					__raiseError
				fi
			fi
		fi

		__printMessage
		__printMessage "${IWHITE}Saving settings ... " ${false}

		ss_SURVEY_FILE="${_input//${ss_STAGING_DIRECTORY}\//%STAGING_DIRECTORY%/}"
		ss_SURVEY_FILE="${ss_SURVEY_FILE//\/\///}"
		ss__saveSetting 'ss_SURVEY_FILE'

		__printMessage "${IGREEN}Done"
	else
		__printMessage
		__printMessage 'Survey file location was not changed.'
	fi

	__printMessage
	__pause

	return 0
}

#ss__checkInvalidSurveyFileEntries()
	#Checks if there are invalid uncommented lines in the survey file
	#Return Codes:	0=No Invalid Entries;	1=Invalid Entries Found
function ss__checkInvalidSurveyFileEntries() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	return $(grep -E -v '^(#.*|\s*)$' "$(ss__getSurveyFileName)" | grep -c -E -v "${ss_SURVEY_ENABLED_REGEX}" || :)
}

#ss__cleanupInstallation()
	#Performs a full cleanup of installed packages and files based on cloudian_cleanup.sh
	#Return Codes:	0=Success
function ss__cleanupInstallation() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0
	local _clusterPassword=''
	local _sshCommand

	__printTitle 'Installation Cleanup'
	__printMessage "This will delete all Cloudian HyperStore software from Cloudian Packages directory (${IWHITE}${ss_STAGING_DIRECTORY}${RST}) and from all the Cloudian Cluster nodes."
	if __getYesNoInput 'Are you sure you want to do this?' "${IRED}No"; then
		if [[ ! -f "$(ss__getSSHKeyFileName)" ]]; then
			__logMessage 'No SSH Key File'
			__printMessage "If your ${USER} password is the same on all (or most) nodes in the cluster, you can supply it as a cluster password"
			__printMessage 'If you do not want to supply a password, each server will prompt for one when connecting.'
			__printMessage
			__getInput 'Cluster Password:' '_clusterPassword' '' ${true} || break
		fi

		__printMessage
		__printMessage "${IWHITE}Performing Cloudian HyperStore Cleanup"
		_sshCommand=$(cat <<-EOF
				for _service in /etc/init.d/cloudian-* /etc/init.d/puppet* /etc/init.d/lsyncd; do
					[[ -n "\${_server}" ]] && \${_service} stop 2>/dev/null
				done

				if [[ -d '/var/run/cloudian' ]]; then
					for _service in /var/run/cloudian/*.pid; do
						kill -9 \$(cat \${_service}) 2>/dev/null
					done
				fi

				killall -9 java redis-server ruby 2>/dev/null

				_tempDirectory="\$(mktemp --directory --tmpdir)"
				for _file in ${ss_STAGING_DIRECTORY}/CloudianHyperStore-*.bin* ${ss_STAGING_DIRECTORY}/*.lic ${ss_STAGING_DIRECTORY}/cloudian-docs*.tar.gz* ${ss_STAGING_DIRECTORY}/system_setup*.sh ${ss_STAGING_DIRECTORY}/preInstallCheck.sh ${ss_STAGING_DIRECTORY}/*.csv ${ss_STAGING_DIRECTORY}/*.pdf ${ss_STAGING_DIRECTORY}/cloudian-installation-key*; do
					mv "\${_file}" "\${_tempDirectory}/" 2>/dev/null
				done

				for _package in \$(rpm -qa *cloudian* *puppet* *jdk* *facter* *diff-backup* lsyncd); do
					rpm -e --nodeps \${_package} || :
				done

				rm -frv "${ss_STAGING_DIRECTORY}" /etc/*.cloudianremove /etc/cloudian* /etc/cron.d/cloudian* /etc/cron.d/redis-crontab /etc/hosts.orig /etc/init.d/cloudian-* /etc/puppet* /etc/resolv.dnsmasq.conf /export/home/cloudian* /opt/* /tmp/cloudian* /tmp/hsperfdata_cloudian /tmp/installer /tmp/puppet_* /tmp/jna* /tmp/liblz4-java* /tmp/snappy* /usr/local/cloudian /var/lib/cassandra* /var/lib/cloudian /var/lib/puppet /var/lib/redis* /var/log/cloudian* /var/log/cassandra /var/log/puppet* /var/log/redis /var/run/cloudian /var/spool/mail/cloudian 2>/dev/null
				find /etc/rc.d -iname "*cloudian*" -exec rm -fv {} \; 2>/dev/null

				mv -v "\${_tempDirectory}" "${ss_STAGING_DIRECTORY}" 2>/dev/null

				#Delete after restoring saved files, otherwise the saved directory will be deleted too
				rm -frv /tmp/tmp* 2>/dev/null

				[[ -f /etc/hosts.cloudian_backup ]] && mv -fv /etc/hosts.cloudian_backup /etc/hosts
				[[ -f /etc/resolv.conf.bak ]] && mv -fv /etc/resolv.conf.bak /etc/resolv.conf
			EOF
		)
		ss__runOnCluster "${_sshCommand}" "${_clusterPassword}" ${true}

		__printMessage "${IGREEN}Completed Installation Cleanup"
	fi

	return 0
}

#ss__configureDisk(Disk, FileSystemType="ext4", Row=-1, Column=-1)
	#Wipe-out, Partition, & Format Disk
		#FileSystemTypes supported: ext4, xfs
		#Row & Column for location to print status messages
	#Return Codes:	0=Success; 1=Invalid/Not Found Disk
		#10=Unknown; 11=System Disk; 12=Unmount Failure; 13=Mountpoint Removal Failure
		#20=Unknown; 21=Partition Removal Failure
		#30=Unknown; 31=Partition Creation Failure
		#40=Unknown; 41=Formatting Failure
	#Exit Codes:	254=Wrong Parameter Count; 255=Missing Required Parameter Value 
function ss__configureDisk() {
	[[ ${#} -lt 1 || ${#} -gt 4 ]] && __raiseWrongParametersError ${#} 1 4

	local IFS

	local -a _cursorPosition=(${3:--1} ${4:--1}) #Default to (-1, -1)
	local _disk="${1:?$(__raiseError 'Disk is required')}"
	local -i _fd _fd2 #Needed during locks below
	local _filesystemType="${2:-ext4}" #Default to EXT4
	local _mount
	local -i _mountpoint=1 #Starting mount number to append to ss_DISK_MOUNTPATH
	local -i _returnCode
	local _uuid

	#private__printMessage(Message)
		#Prints Message using __printStatusMessage if _cursorPosition is greater than (-1, -1)
	function private__printMessage() {
		__logMessage "Disk: ${_disk}; ${1:-}"

		if [[ ${_cursorPosition[0]} -ge 0 && ${_cursorPosition[1]} -ge 0 ]]; then
			__printStatusMessage ${_cursorPosition[*]} "${1:-}" ${false} ${false}
		else
			__printMessage "${1:-}"
		fi

		return ${?}
	}

	[[ ! -b "${_disk}" && -b "/dev/${_disk}" ]] && _disk="/dev/${_disk}"

	private__printMessage "Disk ${IWHITE}${_disk}${RST}: "
	_cursorPosition[1]=$((_cursorPosition[1] + 7 + ${#_disk}))

	[[ ! -b "${_disk}" ]] && private__printMessage "${IRED}Invalid Disk" && return 1
	[[ ! -f "${ss_FSLIST}" ]] && __createFile "${ss_FSLIST}" >/dev/null

	#Remove existing mounts & mount entries from ${FSTAB} & ${ss_FSLIST}
	__logMessage "Removing Disk Mounts: '${_disk}'"
	if ! ss__removeDiskMounts "${_disk}" >/dev/null; then
		_returnCode=${?}
		__logMessage "Removing Disk Mounts Failed (${_returnCode}): '${_disk}'"
		case ${_returnCode} in
			1) private__printMessage "${IRED}Invalid Disk"; return 1 ;;
			2) private__printMessage "${IRED}Cannot configure system used disk"; return 11 ;;
			3) private__printMessage "${IRED}Failed to unmount existing mount point"; return 12 ;;
			4) private__printMessage "${IRED}Failed to remove existing mount point"; return 13 ;;
			*) private__printMessage "${IRED}Unknown error occurred (${_returnCode})"; return 10 ;;
		esac
	fi

	#*** Remove all existing partition data ***
	private__printMessage 'Removing All Partition Data'
	__logMessage "Removing Partition Data: '${_disk}'"
	if ! __zeroDisk "${_disk}" >/dev/null; then
		_returnCode=${?}
		__logMessage "Removing Partition Data Failed (${_returnCode}): '${_disk}'"
		case ${_returnCode} in
			1) private__printMessage "${IRED}Invalid Disk"; return 1;;
			2) private__printMessage "${IRED}Failed to remove existing partition data"; return 21;;
			*) private__printMessage "${IRED}Unknown error occurred (${_returnCode})"; return 20;;
		esac
	fi

	private__printMessage "${IGREEN}Cleaned »"
	_cursorPosition[1]=$((_cursorPosition[1] + 10))

	#*** Create a new partition ***
	partprobe ${_disk} >/dev/null 2>&1 || :
	private__printMessage 'Creating Partition'
	__logMessage "Creating Partition: '${_disk}'"
	if ! ss__partitionDisk "${_disk}" >/dev/null; then
		_returnCode=${?}
		__logMessage "Creating Partition Failed (${_returnCode}): '${_disk}'"
		case ${_returnCode} in
			1) private__printMessage "${IRED}Failed to create new partition"; return 31;;
			*) private__printMessage "${IRED}Unknown error occurred (${_returnCode})"; return 30;;
		esac
	fi
	private__printMessage "${IGREEN}Partitioned » ${RST}Formatting (${_filesystemType})"
	_cursorPosition[1]=$((_cursorPosition[1] + 14))

	#*** Format the partition ***
	partprobe ${_disk} >/dev/null 2>&1 || :
	#__sleepPseudoRandom
	__logMessage "Formatting (${_filesystemType}) Partition: '${_disk}1'"
	if ! ss__formatDisk "${_disk}1" "${_filesystemType}" >/dev/null; then
		_returnCode=${?}
		__logMessage "Formatting (${_filesystemType}) Failed (${_returnCode}): '${_disk}1'"
		case ${_returnCode} in
			1) private__printMessage "${IRED}Failed to format"; return 41;;
			*) private__printMessage "${IRED}Unknown error occurred (${_returnCode})"; return 40;;
		esac
	fi
	private__printMessage "${IGREEN}Formatted » ${RST}Mounting"
	_cursorPosition[1]=$((_cursorPosition[1] + 12))

	#*** Find next mountpoint to use ***
	while :; do #Loop until a lock on the directory is obtained
		while [[ -d "${ss_DISK_MOUNTPATH}${_mountpoint}" ]]; do (( ++_mountpoint )); done
		if __createDirectory "${ss_DISK_MOUNTPATH}${_mountpoint}" >/dev/null 2>&1; then
			exec {_fd}<"${ss_DISK_MOUNTPATH}${_mountpoint}"
			if flock --exclusive --nonblock ${_fd}; then
				__logMessage "Directory Locked: '${ss_DISK_MOUNTPATH}${_mountpoint}', Disk: '${_disk}'"
				chmod 000 "${ss_DISK_MOUNTPATH}${_mountpoint}"

				_uuid="$(blkid -o value -s UUID ${_disk}1)"

				#*** Add fstab entry ***
				exec {_fd2}>>"${FSTAB}"
				(
					while ! flock --exclusive --nonblock ${_fd2}; do
						__logMessage "Waiting for fstab lock: '${_disk}'"
						__sleepPseudoRandom
					done
					__logMessage "Locked ${FSTAB} for: '${_disk}'"

					#clean up old entries from fstab
					sed -i -r -e "/^[^#].*\s${ss_DISK_MOUNTPATH//\//\\/}${_mountpoint}\s.+$/d" "${FSTAB}"
					sed -i -r -e "/^${_disk//\//\\/}1\s.+$/d" "${FSTAB}"
					sed -i -r -e "/^UUID=\"?${_uuid}\"?\s.+$/d" "${FSTAB}"

					#Add new entry to fstab
					printf 'UUID=%s\t%s\t%s\t%s\t0\t1\n' "${_uuid}" "${ss_DISK_MOUNTPATH}${_mountpoint}" "${_filesystemType,,}" "${ss_mountOptions[${_filesystemType,,}]}" >> ${FSTAB}

					flock --unlock ${_fd2}
					__logMessage "Unlocked ${FSTAB} for: '${_disk}'"
				)
				exec {_fd2}>&-

				#*** Add fslist entry ***
				exec {_fd2}>>"${ss_FSLIST}"
				(
					while ! flock --exclusive --nonblock ${_fd2}; do
						__logMessage "Waiting for fslist lock: ${_disk}1"
						__sleepPseudoRandom
					done
					__logMessage "Locked ${ss_FSLIST} for: '${_disk}'"

					#Remove STARTED/COMPLETED lines
					sed -r -i -e '/^(STARTED|COMPLETED) .*$/d' "${ss_FSLIST}"

					#Clean up old entries
					sed -i -r -e "/^[^#].*\s${ss_DISK_MOUNTPATH//\//\\/}${_mountpoint}\b.*$/d" "${ss_FSLIST}"
					sed -i -r -e "/^${_disk//\//\\/}1\s.+$/d" "${ss_FSLIST}"
					sed -i -r -e "/^UUID=\"?${_uuid}\"?\s.+$/d" "${ss_FSLIST}"

					#For HS-43786 - Disable UUID in fslist.txt file and revert back to deviceName
					#printf 'UUID="%s"\t%s\n' "${_uuid}" "${ss_DISK_MOUNTPATH}${_mountpoint}" >> ${ss_FSLIST}
					printf '%s\t%s\n' "${_disk}1" "${ss_DISK_MOUNTPATH}${_mountpoint}" >> ${ss_FSLIST}

					flock --unlock ${_fd2}
					__logMessage "Unlocked ${ss_FSLIST} for: '${_disk}'"
				)
				exec {_fd2}>&-

				flock --unlock ${_fd}
				exec {_fd}>&-
				break
			else
				__logMessage "Directory Lock Failed: '${ss_DISK_MOUNTPATH}${_mountpoint}', Disk: '${_disk}'"
			fi
		else
			__logMessage "Directory Creation Failed: '${ss_DISK_MOUNTPATH}${_mountpoint}', Disk: '${_disk}'"
		fi
	done

	__logMessage "Mounting '${_disk}1' to '${ss_DISK_MOUNTPATH}${_mountpoint}'"
	mount "${ss_DISK_MOUNTPATH}${_mountpoint}"
	__logMessage "Finished Disk: '${_disk}'"
	private__printMessage "${IGREEN}Mounted » Done"

	return 0
}

#ss__configureDisks(Disks)
	#Will configure each disk in Disks in parallel
function ss__configureDisks() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local -a _cursorPosition
	local _disk
	local -a _disks=(${1:?$(__raiseError 'Disks is required')})
	local -i _failedCount=0
	local -i _pid
	local -a _pids

	if [[ ${#_disks[@]} -gt 0 ]]; then
		_disks=($(IFS=$'\n'; sort -u <<<"${_disks[*]}"; unset IFS))
		__printTitle 'Setup Disks' "Configuring: ${_disks[*]}"
		_cursorPosition=($(__getCursorPosition))
		for _disk in "${!_disks[@]}"; do
			( ss__configureDisk "${_disks[${_disk}]}" "${ss_FSTYPE}" $((_disk + ${_cursorPosition[0]})) 0 ) &
			_pids+=(${!})
			__sleepPseudoRandom
		done
		for _pid in ${_pids[@]}; do
			wait ${_pid} || (( ++_failedCount ))
		done
		__setCursorPosition $((${#_disks[@]} + 1 + ${_cursorPosition[0]})) 0
		[[ ${_failedCount} -gt 0 ]] && __printMessage "${IYELLOW}WARNING: ${YELLOW}Failed to configured ${_failedCount} out of ${#_disks[@]} disks"
	else
		__printErrorMessage 'There are no disks selected to configure.'
	fi

	[[ -f "${ss_FSLIST}" ]] && sed -r -i -e '/^(STARTED|COMPLETED) .*$/d' "${ss_FSLIST}"

	return 0
}

#ss__configureHyperStorePrerequisites(AssumeYes=${false})
	#Configures host with HyperStore Prerequisites
	#Return Codes:	0=Success; 1=Failed Package Extraction; 2=Failed Package Installation
	#Exit Codes:	1=Wrong parameter count
function ss__configureHyperStorePrerequisites() {
	[[ ${#} -gt 1 ]] && __raiseWrongParametersError ${#} 0 1
	local -i _assumeYes=${1:-${false}}
	local -a _cursorPosition
	local _package
	local -a _packages

	__printTitle 'Install & Configure Prerequisites'

	__printMessage "${IWHITE}Checking IPTables Status ... " ${false}; _cursorPosition=($(__getCursorPosition)); __printMessage
	if service iptables status 1>/dev/null || chkconfig iptables || service ip6tables status 1>/dev/null || chkconfig ip6tables; then
		__printStatusMessage ${_cursorPosition[*]} "${IRED}Enabled"
		__printMessage
		__printMessage 'HyperStore requires that IPTables is disabled.'
		if (( ${_assumeYes} )) || __getYesNoInput 'Would you like to disable it now?' 'Yes'; then
			__printMessage '\tDisabling IPTables ... ' ${false}
			if chkconfig iptables off && service iptables stop >/dev/null 2>&1; then
				__printMessage "${IGREEN}Done"
			else
				__printMessage "${IRED}Failed"
			fi

			__printMessage '\tDisabling IP6Tables ... ' ${false}
			if chkconfig ip6tables off && service ip6tables stop >/dev/null 2>&1; then
				__printMessage "${IGREEN}Done"
			else
				__printMessage "${IRED}Failed"
			fi
		fi
		__printMessage
	else
		__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Disabled"
	fi

	__printMessage "${IWHITE}Checking SELinux Status ... " ${false}; _cursorPosition=($(__getCursorPosition)); __printMessage
	if [[ "$(getenforce)" =~ "^[^(Disabled|Permissive)]$" ]] || grep -E -i -q "^SELINUX=(enforcing|1)" /etc/selinux/config 2> /dev/null || grep -E -i -q "^SELINUX=(enforcing|1)" /etc/sysconfig/selinux 2> /dev/null; then
		__printStatusMessage ${_cursorPosition[*]} "${IRED}Enabled"
		__printMessage
		__printMessage 'HyperStore requires that SELinux be disabled.'
		if (( ${_assumeYes} )) || __getYesNoInput 'Would you like to disable it now?' 'Yes'; then
			__printMessage '\tDisabling SELinux ... ' ${false}
			[[ -f "/etc/sysconfig/selinux" ]] && sed -i "s~^SELINUX=.*$~SELINUX=disabled~" /etc/sysconfig/selinux
			[[ -f "/etc/selinux/config" ]] && sed -i "s~^SELINUX=.*$~SELINUX=disabled~" /etc/selinux/config
			[[ "$(getenforce)" != "Disabled" ]] && setenforce 0 >/dev/null 2>&1
			__printMessage "${IGREEN}Done"
		fi
		__printMessage
	else
		__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Disabled"
	fi

	#Disable IPv6 since HyperStore currently does not support it and there are known issues with it being enabled
	__printMessage "${IWHITE}Ensuring IPv6 is disabled ... " ${false}
	grep -q -E 'net.ipv6.conf.all.disable_ipv6\s*=\s*1' "${SYSCTL_CONF}" || printf '\n%s\n' 'net.ipv6.conf.all.disable_ipv6 = 1' >> "${SYSCTL_CONF}"
	grep -q -E 'net.ipv6.conf.default.disable_ipv6\s*=\s*1' "${SYSCTL_CONF}" || printf '\n%s\n' 'net.ipv6.conf.default.disable_ipv6 = 1' >> "${SYSCTL_CONF}"
	sysctl -q -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
	__printMessage "${IGREEN}Done"

	#Adjust Kernel messages printing to console
	grep -q -E 'kernel.printk' "${SYSCTL_CONF}" || printf '\n%s\n' 'kernel.printk = 3 4 1 7' >> "${SYSCTL_CONF}"
	sysctl -q -w kernel.printk='3 4 1 7'

	__printMessage "${IWHITE}Installing HyperStore Package Dependencies ... " ${false}; _cursorPosition=($(__getCursorPosition)); __printMessage
	if ss__installBundledPackages; then
		__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done"
		for _package in "${REQUIRED_PACKAGES[@]}"; do
			__checkInstalledPackage "${_package}" || _packages+=("${_package}")
		done
		if [[ ${#_packages[@]} -gt 0 ]]; then
			__printMessage
			__printMessage "${IRED}Not all required packages were installed from bundle."
			__printMessage "Required Packages: ${IWHITE}${_packages[*]}"
			__printMessage
			if (( ${_assumeYes} )) || __getYesNoInput 'Would you like to install them from network repositories?' 'Yes'; then
				if __installPackage 'epel-release' && __installPackage "${_packages[*]}"; then
					__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done"
				else
					__printStatusMessage ${_cursorPosition[*]} "${IRED}Not all required packages could be installed"
					return 2
				fi
			else
				__printStatusMessage ${_cursorPosition[*]} "${IRED}Not all required packages are installed"
				return 2
			fi
		fi
	else
		for _package in "${REQUIRED_PACKAGES[@]}"; do
			__checkInstalledPackage "${_package}" || _packages+=("${_package}")
		done
		if [[ ${#_packages[@]} -gt 0 ]]; then
			if (( ${_assumeYes} )) || __getYesNoInput 'Attempt to install packages from network repositories?' 'yes'; then
				if __installPackage 'epel-release' && __installPackage "${_packages[*]}"; then
					__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done"
				else
					__printStatusMessage ${_cursorPosition[*]} "${IRED}Failed to install required packages"
					return 2
				fi
			else
				__printStatusMessage ${_cursorPosition[*]} "${IRED}Failed to install all required packages"
				return 2
			fi
		fi
	fi

	if ! (( ss_REMOTE )); then
		_packages=()
		for _package in "${OPTIONAL_PACKAGES[@]}"; do
			__checkInstalledPackage "${_package}" || _packages+=("${_package}")
		done
		if [[ ${#_packages[@]} -gt 0 ]]; then
			__printMessage
			__printMessage 'The following packages are not required for a successful installation, but can be very useful to have installed.'
			__printMessage 'Installing these will require a network reachable repository with the proper packages.'
			__printMessage "Optional Packages: ${IWHITE}${_packages[*]}"
			__printMessage
			if (( ${_assumeYes} )) || __getYesNoInput 'Would you like to install them now?' 'Yes'; then
				__printMessage "${IWHITE}Installing extra packages ... " ${false}; _cursorPosition=($(__getCursorPosition)); __printMessage
				if __installPackage 'epel-release' && __installPackage "${_packages[*]}"; then
					__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done"
				else
					__printStatusMessage ${_cursorPosition[*]} "${IRED}Failed"
				fi
			fi
		fi
	fi

	return 0
}

#ss__copyFileToCluster(File, ClusterPassword='')
	#Copies a file from local node to all other cluster nodes
	#Return Codes:	0=Success; 1=File Not Found
	#Exit Codes:	254=Wrong Parameter Count; 255=Missing Required Parameter Value
function ss__copyFileToCluster() {
	[[ ${#} -lt 1 || ${#} -gt 2 ]] && __raiseWrongParametersError ${#} 1 2
	local _clusterPassword="${2:-}"
	local -a _cursorPosition
	local -i _exitCode
	local _file="${1:?$(__raiseError 'File is required')}"
	local _server
	local -i _serverPassword=${false}

	[[ ! -f "${_file}" && ! -d "${_file}" ]] && __printErrorMessage "File '${_file}' not found." && return 1

	ss__installPackage 'sshpass' || :

	__printDebugMessage "File: '${_file}'"
	__printDebugMessage "Directory: '$(__getDirectoryName "${_file}")'"

	__printMessage "Checking and creating remote directory path before transferring '${_file%*/}'"
	ss__runOnCluster "mkdir -p '$(__getDirectoryName "${_file})")'" "${_clusterPassword:-}" ${true}

	__printMessage
	for _server in $(ss__getSurveyFileEntries 'IP'); do
		if [[ "$(hostname -I)" =~ "${_server}" ]]; then
			:
		else
			__printMessage "${ICYAN}══> ${RST}Transferring to Server: ${IWHITE}${_server}${RST} ... " ${false}; _cursorPosition=($(__getCursorPosition))
			__printMessage "${ICYAN}<══"
			while (( ${true} )); do
				_exitCode=0
				if (( ! _serverPassword )) && [[ -f "$(ss__getSSHKeyFileName)" ]]; then
					__printDebugMessage 'Using SSH Key: $(ss__getSSHKeyFileName)'
					if [[ -n "${_clusterPassword}" ]]; then
						__printDebugMessage 'SSH Key + sshpass'
						sshpass -p "${_clusterPassword}" scp -r -i "$(ss__getSSHKeyFileName)" -o 'CheckHostIP=no' -o 'StrictHostKeyChecking=no' -o 'VerifyHostKeyDNS=no' "${_file}" ${_server}:"${_file}" 2>/dev/null || _exitCode=${?}
					else
						scp -r -i "$(ss__getSSHKeyFileName)" -o 'CheckHostIP=no' -o 'StrictHostKeyChecking=no' -o 'VerifyHostKeyDNS=no' "${_file}" ${_server}:"${_file}" 2>/dev/null || _exitCode=${?}
					fi
				elif (( ! _serverPassword )) && [[ -n "${_clusterPassword}" ]]; then
					__printDebugMessage 'Using sshpass'
					sshpass -p "${_clusterPassword}" scp -r -o 'CheckHostIP=no' -o 'StrictHostKeyChecking=no' -o 'VerifyHostKeyDNS=no' "${_file}" ${_server}:"${_file}" 2>/dev/null || _exitCode=${?}
				else
					__printDebugMessage 'Manual Password Entry'
					_serverPassword=${false}
					scp -r -o 'CheckHostIP=no' -o 'StrictHostKeyChecking=no' -o 'VerifyHostKeyDNS=no' "${_file}" ${_server}:"${_file}" 2>/dev/null || _exitCode=${?}
				fi
				case ${_exitCode} in
					0)
						__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done" ${true}
						__printMessage
						break
						;;
					5) __printStatusMessage ${_cursorPosition[*]} "${IRED}Failed - Permission Denied" ${true} ;;
					255) __printStatusMessage ${_cursorPosition[*]} "${IRED}Failed to connect to server" ;;
					*) __printStatusMessage ${_cursorPosition[*]} "${IRED}Unhandled Exit Code: ${_exitCode}" ;;
				esac

				__printMessage
				__getYesNoInput 'Would you like to try a different password?' "${IRED}No" && _serverPassword=${true} || break
			done
		fi
		__printMessage
	done

	return 0
}

#ss__createHostsFile()
	#Creates a default ${HOSTS_FILE} file if one doesn't exist
	#Return Codes:	0=Success
function ss__createHostsFile() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	if [[ -f "${HOSTS_FILE}" && $(grep -c $'\n' "${HOSTS_FILE}") -gt 0 ]]; then
		[[ $(grep -c -E '^::1.*localhost.*$' "${HOSTS_FILE}") -eq 0 ]] && sed -i '1i::1\tlocalhost\tlocalhost.localdomain\tlocalhost6\tlocalhost6.localdomain6' "${HOSTS_FILE}"
		[[ $(grep -c -E '^127.0.0.1.*localhost.*$' "${HOSTS_FILE}") -eq 0 ]] && sed -i '1i127.0.0.1\tlocalhost\tlocalhost.localdomain\tlocalhost4\tlocalhost4.localdomain' "${HOSTS_FILE}"
	elif __createFile "${HOSTS_FILE}"; then
		cat <<-EOF | column -t > "${HOSTS_FILE}"
			127.0.0.1 localhost localhost.localdomain localhost4 localhost4.localdomain
			::1 localhost localhost.localdomain localhost6 localhost6.localdomain6
		EOF
	fi

	return 0
}

#ss__createMountBindPoint(Disk, MountPoint)
	#Configures Disk to be mounted at MountPoint and then creates several directories to 'mount -o bind' against.
	#Return Codes:	0=Success
	#Exit Codes:	1=Invalid disk; 2=Failed to clean; 3=Failed to create partition/filesystem/MountPoint/directory; 4=Failed to mount
function ss__createMountBindPoint() {
	[[ ${#} -ne 2 ]] && __raiseWrongParametersError ${#} 2
	local -a _cursorPosition
	local _directoryName
	local -a _directoryList=(
		'/etc/cloudian-6.1-puppet'
		'/root/CloudianPackages'
		'/root/CloudianTools'
		'/opt'
		'/var/lib/cassandra'
		'/var/lib/cassandra_commit'
		'/var/log/puppetserver'
		'/var/log/cloudian'
		'/var/log/cloudian_sysinfo'
	)
	local _disk="/dev/${1:?$(__raiseError 'Disk is required')}"; _disk="${_disk//\/\///}"; _disk="${_disk//\/dev\/dev\///dev/}"
	local IFS
	local _mountpoint="${2:?$(__raiseError 'MountPoint is required')}"

	#private__createDirectory(DirectoryName)
		#Creates DirectoryName if it does not exist
		#Return Codes:	0=Success; 1=Failed; 2=Exists
	function private__createDirectory() {
		[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
		local _directoryName="${1:?$(__raiseError 'DirectoryName is required')}"

		__printMessage "Creating Directory '${IWHITE}${_directoryName}${RST}' ... " ${false}
		if [[ -d "${_directoryName}" ]]; then
			__printMessage "${IYELLOW}Already Exists"
			return 2
		elif mkdir -p "${_directoryName}"; then
			__printMessage "${IGREEN}Done"
			return 0
		else
			__printMessage "${IRED}Failed"
			return 1
		fi
	}

	#If ${_mountpoint} exists then exit out
	[[ -d "${_mountpoint}" ]] && {
		__printMessage "${IRED}Directory ${_mountpoint} already exists"
		return 1
	}

	#Clean existing mounts
	ss__removeDiskMounts "${_disk}" || {
		case ${?} in
			1) __printErrorMessage 'Invalid disk device' '' 1;;
			2) __printErrorMessage 'Cannot configure system used disk' '' 1;;
			3) __printErrorMessage 'Failed to unmount existing mount point' '' 2;;
			4) __printErrorMessage 'Failed to remove existing mount point';;
			*) __raiseError "Unhandled error occurred cleaning disk (${?})";;
		esac
	}

	#Zero the disk
	__zeroDisk "${_disk}" || {
		case ${?} in
			1) __printErrorMessage 'Invalid Disk' '' 1;;
			2) __printErrorMessage 'Failed to remove existing partition data' '' 2;;
			*) __raiseError "Unknown error occurred (${?})";;
		esac
	}

	#Create a single partition
	ss__partitionDisk "${_disk}" || {
		case ${?} in
			1) __printErrorMessage 'Failed to create new partition' '' 3;;
			*) __raiseError "Unhandled error occurred (${?})";;
		esac
	}

	#Format the partition
	partprobe ${_disk} >/dev/null 2>&1 || : #Tells kernel to reread partition data
	ss__formatDisk "${_disk}1" "${ss_FSTYPE}" || {
		case ${?} in
			1) __printErrorMessage 'Failed to format' '' 3;;
			*) __raiseError "Unknown error occurred (${?})";;
		esac
	}

	#Create MountPoint
	__createDirectory "${_mountpoint}" || {
		case ${?} in
			1) __printErrorMessage 'Failed to create MountPoint' '' 3;;
			*) __raiseError "Unknown error occurred (${?})";;
		esac
	}

	#Remove any existing fstab entries first
	sed -i -r -e "/^[^#].*\s${_mountpoint//\//\\/}\s.*$/d" "${FSTAB}"

	#Add fstab entry
	printf '\n\n%-42s\t%-32s\t%s\t%s\t0\t1\n' "UUID=$(blkid -o value -s UUID ${_disk}1)" "${_mountpoint}" "${ss_FSTYPE}" "rw,noatime,errors=remount-ro,barrier=1,data=ordered" >> ${FSTAB}

	#Mount Disk to MountPoint
	mount "${_mountpoint}" || {
		case ${?} in
			1) __printErrorMessage 'Failed to mount' '' 4;;
			*) __raiseError "Unknown error occurred (${?})";;
		esac
	}

	__printMessage "${IWHITE}Building '${_mountpoint}' Directories ... " ${false}; _cursorPosition=($(__getCursorPosition)); __printMessage
	for _directoryName in "${_directoryList[@]}"; do
		__createDirectory "${_mountpoint}${_directoryName}"
	done
	__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done"

	__printMessage
	__printMessage "${IWHITE}Building Target Directories ... " ${false}; _cursorPosition=($(__getCursorPosition)); __printMessage
	for _directoryName in "${_directoryList[@]}"; do
		private__createDirectory "${_directoryName}" || {
			case ${?} in
				1) exit 3;;
				2)
					__printMessage '	Moving existing contents to new location ... ' ${false}
					mv -f "${_directoryName}" "${_mountpoint}${_directoryName}" >/dev/null 2>&1 || {
						__printMessage "${IRED}Failed"
						exit 3
					}
					__createDirectory "${_directoryName}"
					__printMessage "${IGREEN}Done"
					;;
				*) __raiseError "Unknown error occurred (${?})";;
			esac
		}
		__printMessage "	Adding ${FSTAB} entry ... " ${false}
		printf '%-42s\t%-32s\tnone\tbind\t0\t0\n' "${_mountpoint}${_directoryName}" "${_directoryName}" >> ${FSTAB}
		__printMessage "${IGREEN}Done"

		__printMessage "	Mounting ${_mountpoint}${_directoryName} to ${_directoryName} ... " ${false}
		mount "${_directoryName}" || {
			__printErrorMessage 'Failed to mount' '' 4
		}
		__printMessage "${IGREEN}Done"
	done

	return 0
}

#ss__createNetworkConfig(Interface, Type='ethernet', InterfaceMaster='')
	#Creates a new ifcfg-${Interface} configuration file
		#Types: bond, disabled, ethernet, loopback, slave, vlan
		#InterfaceMaster is required when Type=slave
	#Return Codes:	0=Success; 1=No save/overwrite existing config; 2=Cancelled configuration; 99=${INPUT_LIMIT} reached
	#Exit Codes:	1=Wrong parameter count; 2=Missing required parameter; 3=Unknown Type
function ss__createNetworkConfig() {
	[[ ${#} -lt 1 || ${#} -gt 3 ]] && __raiseWrongParametersError ${#} 1 3
	local _interface="${1:?$(__raiseError 'Interface is required')}"
	local _interfaceMaster="${3:-}"
	local _type="${2:-ethernet}"

	[[ "${_type,,}" == 'slave' ]] && local _interfaceMaster="${3:?$(__raiseError 'InterfaceMaster is required when Type=slave')}"
	[[ "${_type,,}" == 'vlan' ]] && local _interfaceMaster="${3:?$(__raiseError 'InterfaceMaster is required when Type=vlan')}"

	local -a _addressTypes=('Static' 'DHCP' 'Ethernet' 'Cancel')
	local -a _bondingTypes=('Balanced Round Robin' 'Active Backup' 'Balance XOR' 'Broadcast' '802.3ad' 'Balance TLB' 'Balance ALB')
	local -a _cursorPosition

	[[ "${_type,,}" == 'vlan' ]] && {
		_interface="$(__getVLANConfigFileName "${_interfaceMaster}" ${_interface} || __getNewVLANConfigFileName "${_interfaceMaster}" ${_interface})"
		_interface="${_interface##*-}"
	}

	local _addressType
	local _bondingType
	local _configuredIPAddress="$(__printInterfaceConfigValue "${_interface}" 'IPADDR')" _currentIPAddress="$(__printInterfaceIPAddress "${_interface}" ${false} || :)"
	local _input
	local _interfaceConfigFile="${SYSCONFIG_NETWORK_SCRIPTS}/ifcfg-${_interface}"
	local _ipAddress _netmask _router _dns1 _dns2

	__printTitle 'Interface Configuration' "${IWHITE}Hostname:${RST} $(__getHostname || printf '<unset>')\n  ${IWHITE}Interface:${RST} ${_interface}"
	case "${_type,,}" in
		'bond'|'ethernet'|'vlan')
			__getMultipleChoiceInput 'How do you want the IPv4 address configured?' '_addressTypes' '_addressType' "${_addressTypes[0]}" || return ${?}
			__printMessage
			case "${_addressType,,}" in
				'ethernet') #Bring interface up without address
					__printMessage "${IWHITE}Generating ${_interfaceConfigFile} ... " ${false}
					_cursorPosition=($(__getCursorPosition)); __printMessage
					cat <<-EOF > "${_interfaceConfigFile}.new"
						DEVICE="${_interface}"
						TYPE="Ethernet"
						BOOTPROTO="none"
						NM_CONTROLLED="no"
						ONBOOT="yes"
						USERCTL="no"
					EOF
					;;
				'static') #Static IP Configuration
					__getIPAddressInput 'IP Address:' '_ipAddress' "${_currentIPAddress:-${_configuredIPAddress:-0.0.0.0}}" || return ${?}
					if [[ "${_ipAddress:-}" != '0.0.0.0' ]]; then
						_netmask="$(ipcalc -s -m "${_ipAddress}" | awk 'BEGIN {FS="="}; {print $2};')"
						__getIPAddressInput 'Network Mask:' '_netmask' "${_netmask}" || return ${?}
						__getIPAddressInput 'Default Gateway (optional):' '_router' '' ${true} || return ${?}
						__getIPAddressInput 'DNS1 (optional):' '_dns1' '' ${true} || return ${?}
						[[ -n "${_dns1:-}" ]] && {
							__getIPAddressInput 'DNS2 (optional):' '_dns2' '' ${true} || return ${?}
						}
					fi

					__printMessage
					__printMessage "${IWHITE}Generating ${_interfaceConfigFile} ... " ${false}
					_cursorPosition=($(__getCursorPosition)); __printMessage
					cat <<-EOF > "${_interfaceConfigFile}.new"
						DEVICE="${_interface}"
						TYPE="Ethernet"
						BOOTPROTO="none"
						NM_CONTROLLED="no"
						ONBOOT="yes"
						USERCTL="no"
						IPADDR="${_ipAddress:-}"
						NETMASK="${_netmask:-}"
					EOF

					if [[ "${_ipAddress:-}" == '0.0.0.0' ]]; then
						sed -i -e "/^IPADDR=.*$/d" "${_interfaceConfigFile}.new"
						sed -i -e "/^NETMASK=.*$/d" "${_interfaceConfigFile}.new"
					fi

					[[ -n "${_router:-}" ]] && printf "GATEWAY=\"${_router}\"\n" >> "${_interfaceConfigFile}.new"
					[[ -n "${_dns1:-}" ]] && printf "DNS1=\"${_dns1}\"\n" >> "${_interfaceConfigFile}.new"
					[[ -n "${_dns2:-}" ]] && printf "DNS2=\"${_dns2}\"\n" >> "${_interfaceConfigFile}.new"
					;;
				'dhcp') #DHCP Configuration
					__printMessage "${IWHITE}Generating ${_interfaceConfigFile} ... " ${false}
					_cursorPosition=($(__getCursorPosition)); __printMessage
					cat <<-EOF > "${_interfaceConfigFile}.new"
						DEVICE="${_interface}"
						TYPE="Ethernet"
						BOOTPROTO="dhcp"
						NM_CONTROLLED="no"
						ONBOOT="yes"
						USERCTL="no"
					EOF
					;;
				'cancel') return 2;;
			esac

			if __isBeta; then
				__printMessage
				__printMessage "${IRED}Currently IPv6 is not supported."
				if __getYesNoInput 'Would you like to configure this interface for IPv6?' 'Yes'; then
					__printMessage
					__addressTypes=('Static' 'DHCP' 'SLAAC' 'Cancel')
					__getMultipleChoiceInput 'How do you want the IPv6 address configured?' '_addressTypes' '_addressType' "${_addressTypes[0]}" || return ${?}
					[[ "${_addressType,,}" == 'cancel' ]] && return 2
					__printMessage
					__printMessage "${IWHITE}Generating ${_interfaceConfigFile} ... " ${false}; _cursorPosition=($(__getCursorPosition)); __printMessage
					printf 'IPV6INIT="yes"\n' >> "${_interfaceConfigFile}.new"
					case "${_addressType,,}" in
						'dhcp')
							cat <<-EOF >> "${_interfaceConfigFile}.new"
								IPV6_AUTOCONF="no"
								#IPV6_MTU=""
								DHCPV6C="yes"
								DHCPV6C_OPTIONS=""
							EOF
							;;
						'slaac')
							cat <<-EOF >> "${_interfaceConfigFile}.new"
								IPV6_AUTOCONF="yes"
								#IPV6_MTU=""
								DHCPV6C="no"
							EOF
							;;
						'static')
							__printMessage 'Static addresses are currently not validated'
							cat <<-EOF >> "${_interfaceConfigFile}.new"
								IPV6ADDR=""
								IPV6_DEFAULTGW=""
								IPV6_AUTOCONF="no"
								#IPV6_MTU=""
								DHCPV6C="no"
							EOF
					esac
				else
					cat <<-EOF >> "${_interfaceConfigFile}.new"
						IPV6INIT="no"
						IPV6ADDR=""
						IPV6_DEFAULTGW=""
						IPV6_AUTOCONF="no"
						DHCPV6C="no"
					EOF
				fi
			else
				cat <<-EOF >> "${_interfaceConfigFile}.new"
					IPV6INIT="no"
					IPV6ADDR=""
					IPV6_DEFAULTGW=""
					IPV6_AUTOCONF="no"
					DHCPV6C="no"
				EOF
			fi

			case "${_type,,}" in
				'bond')
					__printMessage
					__printMessage "${IWHITE}Bonding Types"
					__getMenuInput 'Mode:' '_bondingTypes' '_bondingType' '' ${INPUT_RETURN_STYLE_SELECTED_INDEX} || {
						__removeFile "${_interfaceConfigFile}.new"
						return 99
					}
					sed -i 's~TYPE="Ethernet"~TYPE="Bond"~ig' "${_interfaceConfigFile}.new"
					printf 'BONDING_OPTS="mode=%s"\n' "${_bondingType}" >> "${_interfaceConfigFile}.new"
					printf 'BONDING_MASTER="yes"\n' >> "${_interfaceConfigFile}.new"
					;;
				'vlan')
					printf 'PHYSDEV="%s"\n' "${_interfaceMaster}" >> "${_interfaceConfigFile}.new"
					printf 'VLAN="yes"\n' >> "${_interfaceConfigFile}.new"
					;;
			esac

			__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done"
			;;
		'slave')
			cat <<-EOF > "${_interfaceConfigFile}"
				DEVICE="${_interface}"
				TYPE="Ethernet"
				BOOTPROTO="none"
				ONBOOT="yes"
				NM_CONTROLLED="no"
				USERCTL="no"
				SLAVE="yes"
				MASTER="${_interfaceMaster}"
			EOF
			return 0
			;;
		'loopback')
			cat <<-EOF > "${_interfaceConfigFile}"
				DEVICE="lo"
				IPADDR="127.0.0.1"
				NETMASK="255.0.0.0"
				NETWORK="127.0.0.1"
				# If you're having problems with gated making 127.0.0.0/8 a martian,
				# you can change this to something else (255.255.255.255, for example)
				BROADCAST="127.255.255.255"
				ONBOOT="yes"
				NAME="loopback"
			EOF
			return 0
			;;
		'disable')
			if grep -i -q "ONBOOT" "${_interfaceConfigFile}"; then
				sed -i -e 's~ONBOOT=.*~ONBOOT="no"~gi' "${_interfaceConfigFile}"
			else
				printf 'ONBOOT="no"\n' >> "${_interfaceConfigFile}"
			fi
			grep -i -q -E "^(MASTER|SLAVE|VLAN).*$" "${_interfaceConfigFile}" && sed -i -r -e 's~(MASTER|SLAVE|VLAN)=.*~~gi' "${_interfaceConfigFile}"
			return 0
			;;
		*) __printFunctionUsage 3 "Unknown interface type (${_type}).";;
	esac

	__printMessage
	__printMessage "Your new settings for '${IWHITE}${_interfaceConfigFile}${RST}' are:"
	cat "${_interfaceConfigFile}.new"
	__printMessage
	__getYesNoInput 'Do you wish to save these settings?' "${IRED}No" || {
		__removeFile "${_interfaceConfigFile}.new"
		return 1
	}
	__printMessage

	__printMessage 'Saving new interface configuration file ... ' ${false}; _cursorPosition=($(__getCursorPosition)); __printMessage
	mv -f "${_interfaceConfigFile}.new" "${_interfaceConfigFile}" || {
		__printStatusMessage ${_cursorPosition[*]} "${IRED}Failed"
		return 1
	}
	__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done"
	__printMessage

	ss__createHostsFile #only creates if doesn't exist
	if [[ -n "${_ipAddress:-}" ]]; then
		if [[ -n "${_currentIPAddress:-}" && "${_ipAddress}" != "${_currentIPAddress:-}" ]] && grep -i -q "${_currentIPAddress:-}" "${HOSTS_FILE}"; then
			__printMessage "Updating ${HOSTS_FILE} ... " ${false}; _cursorPosition=($(__getCursorPosition)); __printMessage
			__printDebugMessage "Changing '${_currentIPAddress}' to '${_ipAddress}'"
			sed -i "s~${_currentIPAddress}~${_ipAddress,,}~g" "${HOSTS_FILE}"
			__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done"
		fi

		if [[ -n "${_configuredIPAddress:-}" && "${_ipAddress}" != "${_currentIPAddress:-}" ]] && grep -i -q "${_configuredIPAddress:-}" "${HOSTS_FILE}"; then
			__printMessage "Updating ${HOSTS_FILE} ... " ${false}; _cursorPosition=($(__getCursorPosition)); __printMessage
			__printDebugMessage "Changing '${_configuredIPAddress}' to '${_ipAddress}'"
			sed -i "s~${_configuredIPAddress}~${_ipAddress,,}~g" "${HOSTS_FILE}"
			__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done"
		fi

		__printMessage
		local _currentDomainname="$(__getDomainName || :)"
		local _currentHostname="$(__getHostname || :)"
		if ! grep -i -q "${_ipAddress}" "${HOSTS_FILE}" && [[ -n "${_currentHostname}:-" ]] && __getYesNoInput "Will ${IWHITE}${_ipAddress}${RST} be the address you use for ${IWHITE}${_currentHostname}${RST} in your survey file?" "${IRED}No"; then
			local _regexPattern="${REGEX_IPADDRESS:1:$((${#REGEX_IPADDRESS} - 2))}"

			if [[ -n "${_currentHostname:-}" && "${_currentHostname,,}" != 'localhost' ]]; then
				sed -i -r -e "/^[^#]${_regexPattern}\s+${_currentHostname}.*$/d" "${HOSTS_FILE}"
				__printMessage "Adding ${IWHITE}${_ipAddress}${RST} to ${IWHITE}${HOSTS_FILE}${RST} ... " ${false}
				if [[ -n "${_currentDomainname:-}" ]]; then
					printf '%s\t%s\t%s\n' "${_ipAddress}" "${_currentHostname,,}.${_currentDomainname,,}" "${_currentHostname,,}" >> "${HOSTS_FILE}"
				else
					printf '%s\t%s\n' "${_ipAddress}" "${_currentHostname,,}" >> "${HOSTS_FILE}"
				fi
				__printMessage "${IGREEN}Done"
			fi
		fi
	fi

	return 0
}

#ss__createResolvConfFile()
	#Creates a default ${SYSCONFIG_NETWORK} file if one doesn't exist
	#Return Codes:	0=Success
function ss__createResolvConfFile() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0
	local _domainName="$(__getDomainName)"

	if [[ ! -f "${RESOLV_CONF}" ]] && __createFile "${RESOLV_CONF}" && [[ -n "${_domainName:-}" ]]; then
		cat <<-EOF > "${RESOLV_CONF}"
			domain ${_domainName}
			search ${_domainName}
		EOF
	fi

	return 0
}

#ss__createSysConfigNetworkFile()
	#Creates a default ${SYSCONFIG_NETWORK} file if one doesn't exist
	#Return Codes:	0=Success
function ss__createSysConfigNetworkFile() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	if [[ ! -f "${SYSCONFIG_NETWORK}" ]] && __createFile "${SYSCONFIG_NETWORK}"; then
		cat <<-EOF > "${SYSCONFIG_NETWORK}"
			NETWORKING="yes"
			NOZEROCONF="yes"
			HOSTNAME="$(__getHostname || :)"
		EOF
	fi

	return 0
}

#ss__disableAutoResume()
	#Removes auto launching at login and resume marker
	#Return Codes:	0=Success
	#Exit Codes:	254=Invalid Parameter Count
function ss__disableAutoResume() {
	#Dependencies:	__getDirectoryName, __getFileName, __removeFile
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	__removeFile "$(__getDirectoryName)/$(__getFileName).resume"
	sed -i -r -e "\~^$(__getDirectoryName)/$(__getFileName) .*$~d" ~/.bash_profile

	return 0
}

#ss__editSurveyFileEntry()
	#Prints current entries in survey file for editing
	#Return Codes:	0; 1=No Entries
function ss__editSurveyFileEntry() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0
	local -a _menuOptions
	local _line
	local _selection
	local _responseDefaultStyle=${DEFAULT_RESPONSE_AS_INPUT}
	local _datacenter _hostname _interface _ip _ipLookup _rack _region

	while (( ${true} )); do
		__printTitle 'Edit Entry'

		while read _line; do
			__printDebugMessage "Processing: ${_line}"
			if [[ ${#_menuOptions[@]} -eq 0 ]]; then #Headers from ss__getSurveyFileEntries
				_menuOptions+=("==${_line}")
			elif [[ "${_line:0:1}" == '#' ]]; then #Remarked entries
				_menuOptions+=("${IRED}${_line}")
			else #Active entries
				_menuOptions+=("${IGREEN}${_line}")
			fi
		done < <(ss__getSurveyFileEntries 'all' ${true} ${true} | column -t -s '	' 2>/dev/null)

		__printDebugMessage "Entry Count: ${#_menuOptions[@]}"
		__isColorsLoaded && [[ ${#_menuOptions[@]} -eq 1 ]] && return 1
		! __isColorsLoaded && [[ ${#_menuOptions[@]} -eq 2 ]] && return 1

		_menuOptions+=(
			''
			"P=${IYELLOW}Return to the previous menu"
		)

		__getMenuInput 'Choice:' '_menuOptions' '_selection' || __raiseError 'Exiting after too many failed attempts to make a selection.' 1
		[[ "${_selection}" == 'P' ]] && break #Return to the previous menu

		__printTitle 'Edit Entry'
		__printMessage "         ${IWHITE}${UNDR}${_menuOptions[0]:2}"
		__isColorsLoaded || {
			printf -v line '%*s' $(__removeEscapeCodes "${_menuOptions[0]:2}" | wc -m)
			__printMessage "         $(printf '%s\n' "${line// /-}")"
		}
		__printMessage "Editing: $(__removeEscapeCodes "${_menuOptions[${_selection}]}")"
		__printMessage

		read _region _hostname _ip _datacenter _rack _interface < <(__removeEscapeCodes "${_menuOptions[${_selection}]}")
		_menuOptions[${_selection}]="${_region,,},${_hostname,,},${_ip},${_datacenter,,},${_rack,,}$([[ -n "${_interface,,}" ]] && printf ',')${_interface}"

		DEFAULT_RESPONSE_AS_INPUT=${true}
		__getInput 'Region Name:' '_region' "${_region:-}" ${false} "${ss_regionRegEx}" || continue
		__getInput 'Hostname:' '_hostname' "${_hostname:-}" ${false} "${ss_hostnameRegEx}" || continue
		__printMessage "${IWHITE}Attempting auto IP resolution for ${_hostname,,} ... " ${false}
		_ipLookup="$(timeout 2s getent ahostsv4 "${_hostname}" | awk '{ print $1; exit; };')"
		[[ -n "${_ipLookup}" ]] && __printMessage "${IGREEN}Done" || __printMessage 'nothing discovered'
		__getIPAddressInput 'IP Address:' '_ip' "${_ipLookup:-${_ip:-}}" || continue
		__getInput 'Data Center Name:' '_datacenter' "${_datacenter:-}" ${false} "${ss_datacenterRegEx}" || continue
		__getInput 'Rack name:' '_rack' "${_rack:-}" ${false} "${ss_rackRegEx}" || continue
		__getInput 'Internal Interface (optional):' '_interface' "${_interface}" ${false} "^(${ss_interfaceRegEx:1:$((${#ss_interfaceRegEx} - 2))}|)$" || continue
		[[ -n "${_interface}" ]] && _interface=",${_interface}"

		DEFAULT_RESPONSE_AS_INPUT=${_responseDefaultStyle}

		__printMessage
		__printMessage "${IWHITE}Editing entry in $(ss__getSurveyFileName) ... " ${false}
		sed -i 's~^'${_menuOptions[${_selection}]}'~'${_region,,}','${_hostname}','${_ip}','${_datacenter}','${_rack}${_interface}'~i' "$(ss__getSurveyFileName)"
		__printMessage "${IGREEN}Done"
		__printMessage
		__pause
		_menuOptions=()
	done

	DEFAULT_RESPONSE_AS_INPUT=${_responseDefaultStyle}
}

#ss__enableAutoResume(Arguments)
	#Relaunches script with supplied Arguments
	#Return Codes:	0=Success
	#Exit Codes:	254=Invalid Parameter Count
function ss__enableAutoResume() {
	#Dependencies:	__createFile, __getDirectoryName, __getFileName, __raiseError, __raiseWrongParametersError
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _arguments="${1:?$(__raiseError 'Arguments is required')}"

	__createFile "$(__getDirectoryName)/$(__getFileName).resume"
	printf '%s\n' "$(__getDirectoryName)/$(__getFileName) ${_arguments}" >> ~/.bash_profile

	return 0
}

#ss__extractHyperStoreBinary(TargetDirectory="${ss_STAGING_DIRECTORY}", HyperStoreBinaryFile="$(ss__printNewestHyperStoreBinaryVersion))
	#Extracts ${HyperStoreBinaryFile} to ${TargetDirectory}
	#If HyperStoreBinaryFile is unset then it will be defaulted to highest version found in ${ss_STAGING_DIRECTORY}
	#Return Codes:	0=Success; 1=HyperStoreBinaryFile not found; 2=Failed to extract
	#Exit Codes:	1=Wrong parameters
function ss__extractHyperStoreBinary() {
	#Dependencies:  __printDebugMessage, ss__printNewestHyperStoreBinaryVersion, __raiseWrongParametersError, __removeDirectory
	[[ ${#} -gt 2 ]] && __raiseWrongParametersError ${#} 0 2
	local _targetDirectory="${1:-${ss_STAGING_DIRECTORY}}"
	local _hyperstoreBinaryFile="${2:-$(ss__printNewestHyperStoreBinaryVersion)}"

	[[ ! -f "${_hyperstoreBinaryFile}" ]] && return 1
	[[ ! -d "${_targetDirectory}" ]] && __createDirectory "${_targetDirectory}"

	__printDebugMessage "${IWHITE}Extracting: ${RST}${_hyperstoreBinaryFile}"
	__printDebugMessage "        ${IWHITE}To: ${RST}${_targetDirectory}"
	tail -n+$(awk '/^__ARCHIVE_BELOW__/ {print NR + 1; exit 0; }' "${_hyperstoreBinaryFile}") "${_hyperstoreBinaryFile}" | tar -xOz ./cloudian-*.tar.gz | tar -xz -C "${_targetDirectory}" || return 2

	return 0
}

#ss__extractHyperStoreBinaryPackagedFile(FileName, TargetDirectory="${ss_STAGING_DIRECTORY}", HyperStoreBinaryFile="$(ss__printNewestHyperStoreBinaryVersion)")
	#Extracts FileName from HyperStoreBinaryFile
	#If HyperStoreBinaryFile is unset then it will be defaulted to the highest version found in ${ss_STAGING_DIRECTORY}
	#Return Codes:	0=Success; 1=HyperStoreBinaryFile not found; 3=FileName not found; 4=Could not create/use TargetDirectory
	#Exit Codes:	1=Wrong parameters
function ss__extractHyperStoreBinaryPackagedFile() {
	#Dependencies:	__printErrorMessage, __raiseError, __raiseWrongParametersError
	[[ ${#} -lt 1 || ${#} -gt 3 ]] && __raiseWrongParametersError ${#} 1 3
	local _hyperstoreBinaryFile="${3:-$(ss__printNewestHyperStoreBinaryVersion)}"
	local _file="${1:?$(__raiseError 'FileName is required')}"
	local _targetDirectory="${2:-${ss_STAGING_DIRECTORY}}"

	[[ ! -f "${_hyperstoreBinaryFile}" ]] && return 1
	__createDirectory "${_targetDirectory}" >/dev/null || return 4

	tail -n+$(awk '/^__ARCHIVE_BELOW__/ {print NR + 1; exit 0; }' "${_hyperstoreBinaryFile}") "${_hyperstoreBinaryFile}" | tar -xOz ./cloudian-*.tar.gz | tar -xz -C "${_targetDirectory}" "${_file}" || return 1

	return 0
}

#ss__extractPackagedFile(RPM, TargetDirectory="$(pwd)", HyperStoreBinaryFile="$(ss__printNewestHyperStoreBinaryVersion)")
	#Extracts RPM from HyperStoreBinaryFile selfextract_prereq.bin
	#If HyperStoreBinaryFile is unset then it will be defaulted to highest version found in ${ss_STAGING_DIRECTORY}
	#Return Codes:	0=Success;	1=self_extract.bin not found; 2=Staging Directory not found; 3=RPM not found; 4=Could not create/use TargetDirectory
	#Exit Codes:	1=Wrong parameters
function ss__extractPackagedFile() {
	#Dependencies:	__printErrorMessage, __raiseError, __raiseWrongParametersError
	[[ ${#} -lt 1 || ${#} -gt 3 ]] && __raiseWrongParametersError ${#} 1 3
	local _hyperstoreBinaryFile="${3:-$(ss__printNewestHyperStoreBinaryVersion)}"
	local _rpm="${1:?$(__raiseError 'RPM is required')}"
	local _targetDirectory="${2:-$(pwd)}"

	[[ ! -d "${ss_STAGING_DIRECTORY}" ]] && {
		__printDebugMessage "Staging Directory: ${ss_STAGING_DIRECTORY}"
		return 2
	}
	[[ ! -f "${ss_STAGING_DIRECTORY}/selfextract_prereq.bin" && ! -f "${_hyperstoreBinaryFile}" ]] && return 1
	__createDirectory "${_targetDirectory}" >/dev/null || return 4

	if [[ ! -f "${ss_STAGING_DIRECTORY}/selfextract_prereq.bin" ]]; then
		ss__extractHyperStoreBinaryPackagedFile 'selfextract_prereq.bin' "${ss_STAGING_DIRECTORY}" "${_hyperstoreBinaryFile}" || return ${?}
	fi

	tail -n+$(awk '/^__ARCHIVE_BELOW__/ {print NR + 1; exit 0; }' "${ss_STAGING_DIRECTORY}/selfextract_prereq.bin") "${ss_STAGING_DIRECTORY}/selfextract_prereq.bin" | tar -xOz ./rpm.tar | tar --wildcards -x -C "${_targetDirectory}" "${_rpm}*" 2>/dev/null || return 3

	return 0
}

#ss__formatDisk(Disk, FileSystem='ext4')
	#Formats Disk with specified FileSystem
	#Return Codes:	0=Success; 1=Failed Formatting
function ss__formatDisk() {
	[[ ${#} -lt 1 || ${#} -gt 2 ]] && __raiseWrongParametersError ${#} 1 2
	local IFS
	local -a _cursorPosition
	local _disk="${1:?$(__raiseError 'Disk is required')}"
	local _fileSystem="${2:-ext4}"

	[[ ! -b "${_disk}" ]] && __raiseError "${_disk} is not a valid block device"

	__printMessage "Formatting ${_disk} as ${_fileSystem} ... " ${false}
	_cursorPosition=($(__getCursorPosition)); __printMessage
	case "${_fileSystem,,}" in
		'ext4')
			if ! mkfs.ext4 -q -i 8192 -m 0 -E lazy_itable_init=1,discard -O dir_index,extent,flex_bg,large_file,sparse_super,uninit_bg "${_disk}" >/dev/null 2>&1; then
				__printStatusMessage ${_cursorPosition[*]} "${IRED}Failed"
				return 1
			else
				tune2fs -m 0 "${_disk}" >/dev/null 2>&1 #Ensure Reserve Block count is 0%
			fi
			;;
		'xfs')
			if ! mkfs.xfs -q -f "${_disk}" >/dev/null 2>&1; then
				__printStatusMessage ${_cursorPosition[*]} "${IRED}Failed"
				return 1
			fi
			;;
	esac
	__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done"

	return 0
}

#ss__generateSSHKeyFile(SSHKeyFileFullPath)
	#Will generate a new SSH Key file
	#Return Codes:	0=Success; 1=File Still Exists; 2=Failed to create new key
	#Exit Codes:	0
function ss__generateSSHKeyFile() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _sshKeyFile="${1:?$(__raiseError 'SSHKeyFileFullPath is required')}"

	if [[ -f "${_sshKeyFile}" ]]; then
		if __getYesNoInput 'File already exists, do you want to overwrite?'; then
			__printMessage
			__removeFile "${_sshKeyFile}" || return ${?}
		else
			return 1
		fi
	fi

	__printMessage
	__printMessage "${IWHITE}Creating SSH Key File ... " ${false}
	if ssh-keygen -q -P '' -C '' -f "${_sshKeyFile}"; then
		__printMessage "${IGREEN}Done"
	else
		__printMessage "${IRED}Failed"
		return 2
	fi

	return 0
}

#ss__getDisks(PrintHeadings=${false})
	#Outputs disk entries from lsblk
	#Return Codes:	0=Disks Found; 1=No Disks Found
	#Exit Codes:	1=Invalid Arguments
function ss__getDisks() {
	[[ ${#} -gt 1 ]] && __raiseWrongParametersError ${#} 0 1
	local -i _dependencies
	local -a _disks
	local _disk _mountpoint _size _type
	local -i _printHeadings=${1:-${false}}

	while read _disk _type _size _mountpoint; do
		__printDebugMessage "Processing: ${_disk}, ${_type}, ${_size}" >&2
		case "${_type,,}" in
			'disk')
				[[ ${#_disks[@]} -gt 0 ]] && _disks[$((${#_disks[@]} - 1))]+=":${_dependencies}"
				_disks+=("${_disk}:${_size}")
				_dependencies=0
				;;
			'dmraid')
				__printDebugMessage "dmraid device: ${_disk}; size: ${_size}" >&2
				(( ++_dependencies ))
				;;
			'lvm')
				__printDebugMessage "lvm device: ${_disk}; size: ${_size}" >&2
				(( ++_dependencies ))
				;;
			'part')
				__printDebugMessage "partition: ${_disk}; size: ${_size}" >&2
				(( ++_dependencies ))
				;;
			'raid'*)
				__printDebugMessage "raid (${_type}) device: ${_disk}; size: ${_size}" >&2
				(( ++_dependencies ))
				;;
			'rom'*) __printDebugMessage "Ignoring ${_type} device: ${_disk}; size: ${_size}" >&2;;
			*)
				__printErrorMessage "Unhandled Device Type (${_type}): ${_disk}; size: ${_size})"
				__pause
				;;
		esac
	done < <(lsblk --noheadings --output KNAME,TYPE,SIZE,MOUNTPOINT --raw)
	[[ ${#_disks[@]} -gt 0 ]] && _disks[$((${#_disks[@]} - 1))]+=":${_dependencies}"

	(( _printHeadings )) && printf "Device\tSize\tDependencies\n"
	_disks=($(IFS=$'\n'; sort -u <<<"${_disks[*]}"; unset IFS))
	printf "${_disks[*]}" | awk 'BEGIN {FS=":"; OFS="\t"; RS=" "; ORS="\n"} {print $1, $2, $3}'

	return $(( ! ${#_disks[@]} ))
}

#ss__getSSHKeyFileName()
	#Prints out the parsed value of ss_SSH_KEY_FILE
function ss__getSSHKeyFileName() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	printf '%s' "${ss_SSH_KEY_FILE//'%STAGING_DIRECTORY%'/${ss_STAGING_DIRECTORY}}"
}

#ss__getSurveyFileEntries(OutputField='all', IncludeDisabledEntries=${false}, PrintHeadings=${false})
	#Outputs OutputField entries from ss_SURVEY_FILE
		#If IncludeDisabledEntries is true, also outputs entries that are remarked
		#If PrintHeadings is true, the OutputField value will printed as headings
	#OutputField Options:	all; datacenter; hostname; interface; ip; rack; region
		#Multiple options can selected with a ', ' separated list of choices (example: 'ip, hostname')
	#Return Codes:	0=Entries Found; 1=No Entries Found
	#Exit Codes:	1=Invalid Arguments
function ss__getSurveyFileEntries() {
	[[ ${#} -gt 3 ]] && __raiseWrongParametersError ${#} 0 3
	local -i _includeDisabledEntries=${2:-${false}}
	local _outputField="${1:-all}"
	local _outputHeadings=''
	local -i _printHeadings=${3:-${false}}
	local -r _regexPattern='^((all|region|hostname|ip|datacenter|rack|interface)(, ?)?)+$'
	local -i _returnCode=0

	_outputField="$(__removeEscapeCodes "${_outputField,,}")"
	__printDebugMessage "_outputField=${_outputField}"
	if [[ "${_outputField}" =~ ${_regexPattern} ]]; then
		_outputField="${_outputField//all/\$1, \$2, \$3, \$4, \$5, \$6}"
		_outputField="${_outputField//region/\$1}"
		_outputField="${_outputField//hostname/\$2}"
		_outputField="${_outputField//ip/\$3}"
		_outputField="${_outputField//datacenter/\$4}"
		_outputField="${_outputField//rack/\$5}"
		_outputField="${_outputField//interface/\$6}"

		__printDebugMessage "_outputField => '${_outputField}'"

		(( _printHeadings )) && { #Build awk print statement for headings
			_outputHeadings="; print ${_outputField//\$1/"Region"}"
			_outputHeadings="${_outputHeadings//\$2/"Hostname"}"
			_outputHeadings="${_outputHeadings//\$3/"IP Address"}"
			_outputHeadings="${_outputHeadings//\$4/"Datacenter"}"
			_outputHeadings="${_outputHeadings//\$5/"Rack"}"
			_outputHeadings="${_outputHeadings//\$6/"Interface"}"
		}
		__printDebugMessage "_outputHeadings => '${_outputHeadings}'"

		if (( _includeDisabledEntries )); then
			grep -E "${ss_SURVEY_DISABLED_REGEX}" "$(ss__getSurveyFileName)" 2>/dev/null | awk 'BEGIN {FS=","; OFS="	"'"${_outputHeadings}"'}; { if($6 == "") { $6 = " "}; {'"print ${_outputField}"'} }' || _returnCode=${?}
		else
			grep -E "${ss_SURVEY_ENABLED_REGEX}" "$(ss__getSurveyFileName)" 2>/dev/null | awk 'BEGIN {FS=","; OFS="	"'"${_outputHeadings}"'}; { if($6 == "") { $6 = " "}; {'"print ${_outputField}"'} }' || _returnCode=${?}
		fi

		(( _returnCode )) && __printMessage "${IRED}No Entries Found" >&2

		return ${_returnCode}
	else
		__printFunctionUsage 1 "Invalid OutputField option (${_outputField})"
	fi
}

#ss__getSurveyFileEntryInputs(PrintCurrentEntries=${false})
	#Prompts for survey entry values and adds it into the survey file
		#If PrintCurrentEntries is true, a table of the current entries will be printed
	#Return Codes:	0
function ss__getSurveyFileEntryInputs() {
	[[ ${#} -gt 1 ]] && __raiseWrongParametersError ${#} 0 1
	local _datacenter _hostname _interface _ip _ipLookup _rack _region
	local _name _number
	local -i _printCurrentEntries=${1:-${false}}
	local _responseDefaultStyle=${DEFAULT_RESPONSE_AS_INPUT}

	#Pre-load last entry values
	read _region _hostname _ip _datacenter _rack _interface < <(ss__getSurveyFileEntries 'all' ${false} ${false} 2>/dev/null | tail -n 1 2>/dev/null || :)
	[[ -n "${_region:-}" ]] && _region="$(__removeEscapeCodes "${_region}")"

	while (( ${true} )); do
		__printTitle 'Add Entry'
		(( _printCurrentEntries )) && ss__printSurveyFileEntries ${true} && __printMessage

		if [[ -n "${_hostname:-}" ]]; then #Increment hostname trailing number
			_name="${_hostname}"
			while [[ "${_name:$(( ${#_name} - 1 ))}" =~ [[:digit:]] ]]; do _name="${_name:0:$(( ${#_name} - 1))}"; done
			if [[ "${_name}" != "${_hostname}" ]]; then
				_number="${_hostname//${_name}}"
				_hostname="${_name}$(printf "%0${#_number}d" "$(( ${_number} + 1))")"
			fi
		fi

		#Increment ip address by 1
		[[ -n "${_ip:-}" ]] && _ip="$(__intToIP $(( $(__ipToInt "${_ip}") + 1 )))"

		DEFAULT_RESPONSE_AS_INPUT=${true}
		__getInput 'Region Name:' '_region' "${_region:-}" ${false} "${ss_regionRegEx}" || break
		__getInput 'Hostname:' '_hostname' "${_hostname:-}" ${false} "${ss_hostnameRegEx}" || break
		__printMessage "${IWHITE}Attempting auto IP resolution for ${_hostname} ... " ${false}
		_ipLookup="$(timeout 2s getent ahostsv4 "${_hostname}" | awk '{ print $1; exit; };')"
		[[ -n "${_ipLookup}" ]] && __printMessage "${IGREEN}Done" || __printMessage 'nothing discovered'
		__getIPAddressInput 'IP Address:' '_ip' "${_ipLookup:-${_ip:-}}" || break
		__getInput 'Data Center Name:' '_datacenter' "${_datacenter:-}" ${false} "${ss_datacenterRegEx}" || break
		__getInput 'Rack name:' '_rack' "${_rack:-}" ${false} "${ss_rackRegEx}" || break
		__getInput 'Internal Interface (optional):' '_interface' '' ${false} "(${ss_interfaceRegEx})?" || break
		DEFAULT_RESPONSE_AS_INPUT=${false}

		__printMessage
		if [[ ! -f "$(ss__getSurveyFileName)" ]]; then
			__createDirectory "$(__getDirectoryName "$(ss__getSurveyFileName)")" || __raiseError 'Failed to create directory' 1
			__createFile "$(ss__getSurveyFileName)" || __raiseError 'Failed to create file' 1
		fi
		ss__addSurveyFileEntry "$(ss__getSurveyFileName)" "${_region,,}" "${_hostname}" "${_ip}" "${_datacenter}" "${_rack}" "${_interface}"
		__printMessage
		__getYesNoInput 'Would you like to add another entry?' 'Yes' || break
	done

	DEFAULT_RESPONSE_AS_INPUT=${_responseDefaultStyle}

	return 0
}

#ss__getSurveyFileName()
	#Prints out the parsed value of ss_SURVEY_FILE
function ss__getSurveyFileName() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	printf '%s' "${ss_SURVEY_FILE//'%STAGING_DIRECTORY%'/${ss_STAGING_DIRECTORY}}"
}

#ss__getTimezone()
	#Return Codes:	0
function ss__getTimezone() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0
	local _country _countryCode _selectedRegion _regionName _zone
	local -a _countries _regions _zones
	local IFS

	while (( ${true} )); do
		IFS=$'\n'
		_regions=(
			$(grep -v '^#' "${TZ_ZONE_TABLE}" | awk 'BEGIN {FS="\t"} {split($3, regions, "/"); print regions[1]}' | sort -u)
			''
			"P=${IYELLOW}Return to the previous menu"
		)
		unset IFS

		__printTitle 'Configure Timezone'
		__getMenuInput 'Region:' '_regions' '_regionName' || return ${?}
		[[ "${_regionName}" == 'P' ]] && break #Return to the previous menu
		_regionName="${_regions[$(( ${_regionName} - 1 ))]}"

		while (( ${true} )); do
			IFS=$'\n'
			_countries=(
				$(join -t $'\t' -o 1.1,1.3,2.2 <(grep -v "^#" "${TZ_ZONE_TABLE}" | sort) <(grep -v "^#" "${TZ_COUNTRY_TABLE}" | sort) | awk -v region="${_regionName}" 'BEGIN {FS="\t"} {split($2, regions, "/"); if(regions[1] == region) { print $3 } }' | sort -u)
				''
				"P=${IYELLOW}Return to the previous menu"
			)
			unset IFS

			if [[ ${#_countries[@]} -eq 3 ]]; then
				_country="${_countries[0]}"
			else
				__printTitle 'Configure Timezone' "Region: ${_regionName}"
				__getMenuInput 'Country:' '_countries' '_country' || return ${?}
				[[ "${_country}" == 'P' ]] && break #Return to the previous menu
				_country="${_countries[$(( ${_country} - 1 ))]}"
			fi
			_countryCode="$(awk -v country="${_country}" 'BEGIN {FS="\t"} {if($2 == country) print $1}' "${TZ_COUNTRY_TABLE}")"

			while (( ${true} )); do
				IFS=$'\n'
				_zones=(
					$(awk -v countryCode="${_countryCode}" -v region="${_selectedRegion:-${_regionName}}" 'BEGIN {FS="\t"} {if($1 == countryCode && $3 ~ region) { sub(region "/", "", $3); split($3, zone, "/"); sub("_", " ", zone[1]); print zone[1]; } }' "${TZ_ZONE_TABLE}" | sort -u)
					''
					"P=${IYELLOW}Return to the previous menu"
				)
				unset IFS

				__printTitle 'Configure Timezone' "Country Code: ${_countryCode}, Region: ${_selectedRegion:-${_regionName}}"
				if [[ ${#_zones[@]} -eq 3 ]]; then
					_zone="${_zones[0]}"
				else
					__getMenuInput 'Zone:' '_zones' '_zone' || return ${?}
					if [[ "${_zone}" == 'P' ]]; then #Return to the previous menu
						[[ -z "${_selectedRegion:-}" ]] && {
							unset _selectedRegion
							break
						}
						[[ "${_selectedRegion}" != "${_selectedRegion%/*}" ]] && _selectedRegion="${_selectedRegion%/*}" || { unset _selectedRegion; break; }
						continue
					fi
					_zone="${_zones[$(( ${_zone} - 1 ))]}"
				fi
				_selectedRegion="${_selectedRegion:-${_regionName}}/${_zone}"
				_selectedRegion="${_selectedRegion// /_}"

				__printDebugMessage "_country: ${_country}; _countryCode: ${_countryCode}"
				__printDebugMessage "_regionName: ${_regionName}"
				__printDebugMessage "_selectedRegion: ${_selectedRegion}"

				[[ -d "${TZ_DIR}/${_selectedRegion}" ]] && continue
				if [[ -f "${TZ_DIR}/${_selectedRegion}" ]]; then
					ss__setTimezone "${_selectedRegion}" && break 3
					if [[ ${#_countries[@]} -eq 3 && ${#_zones[@]} -eq 3 ]]; then #Only one country & region, return to two previous menus
						unset _countryCode _selectedRegion
						break 2
					elif [[ ${#_zones[@]} -gt 3 && "${_selectedRegion}" != "${_selectedRegion%/*}" ]]; then
						_selectedRegion="${_selectedRegion%/*}"
					else
						unset _selectedRegion
						break
					fi
				else
					__raiseError 'Selection is not a directory or file. What was selected?'
				fi
			done
		done
	done

	return 0
}

#ss__hyperStoreOVAPrep(Hypervisor=[prompt], HyperStoreVersion=[prompt])
	#Prepares current virtual machine for HyperStore deployment and exporting to OVA
	#If Hypervisor or HyperStoreVersion is not supplied a prompt will be presented to pick the desired build release
	#Return Codes:	0=Success
function ss__hyperStoreOVAPrep() {
	[[ ${#} -gt 2 ]] && __raiseWrongParametersError ${#} 0 2
	local -a _cursorPosition
	local _hyperstoreVersion="${2:-}"
	local _hypervisor="${1:-}"
	local -a _hypervisors=('Hyper-V' 'Other' 'VirtualBox' 'VMware')

	__printTitle 'Prepare HyperStore Virtual Appliance' 'This will remove existing network details, login history and bash history'
	__setClearScreenState 1

	if [[ -f "$(__getDirectoryName)/$(__getFileName).resume" ]] || __getYesNoInput 'Are you sure you want to continue?' 'Yes'; then
		if [[ -f "$(__getDirectoryName)/$(__getFileName).resume" ]]; then
			__printMessage 'Resuming OVA Prep after reboot ... '
			__pause
			[[ ! -f "$(__getDirectoryName)/$(__getFileName).resume" ]] && exit 0
			ss__disableAutoResume
			__disableAutoLogin
		else
			if ss__hyperstoreSysPrep "${_hyperstoreVersion}"; then
				if (( ${ss_REBOOT} )); then
					__printMessage 'Need to reboot since a new kernel was installed.'
					__printMessage 'This script will automatically resume after rebooting.'
					ss__enableAutoResume "--ova-prep ${_hypervisor} ${_hyperstoreVersion}"
					__enableAutoLogin
					__reboot
				fi
			else
				exit 1
			fi
		fi

		ss__hyperstoreVMPrep "${_hypervisor}" "${_hyperstoreVersion}" ${false}

		__printMessage
		__printMessage "${IWHITE}Pausing to allow any modifications before cleaning system"
		__printMessage "Now is a good time to login and check things out and make adjustments"
		__pause

		__printMessage 'Removing udev network rules ... ' ${false}
		rm -f /etc/udev/rules.d/*-persistent-net.rules
		__printMessage "${IGREEN}Done"

		__printMessage 'Clearing bach and login history ... ' ${false}
		rm -f ~/.bash_history /var/log/lastlog
		history -c
		__printMessage "${IGREEN}Done"

		__printMessage 'Removing network configurations and setting eth0 to DHCP ... ' ${false}
		_cursorPosition=($(__getCursorPosition)); __printMessage
		rm -f ${SYSCONFIG_NETWORK_SCRIPTS}/ifcfg-* /etc/resolv.conf
		ss__createNetworkConfig 'lo' 'loopback'
		ss__createNetworkConfig 'eth0' 'ethernet' <<-EOF
			DHCP
			Yes
			DHCP
			Yes
		EOF
		ss__setHostname 'hyperstore-01'
		ss__setDomainName 'example.com'
		__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done"

		__printMessage 'All setting have been updated. Please shutdown the machine and export to OVA now.'
		if __getYesNoInput 'Would you like to shutdown now?' 'Yes'; then
			shutdown -P +1 &
			__printMessage
			__printMessage "To cancel shutdown, type 'shutdown -c'"
			exit 0
		else
			ss_REBOOT=${true}
		fi
	fi
}

#ss__hyperstoreSysPrep(HyperStoreVersion=[prompt])
	#Prepares current system for HyperStore deployment by building staging directory with HyperStoreVersion release
	#If HyperStoreVersion is not supplied, a prompt will be presented to pick the desired build release
	#Return Codes:	0=Success
		#			1=Failed Update/Failed Package Extraction
		#			2=Failed Package Install
		#			3=Failed create Staging Directory
		#			4=Failed Downloading Files List
		#			5=Failed to remove versions.txt
		#			6=Failed to download files
		#			7=Cleaning Packages
		#			8=Making Package Cache
		#			99=${INPUT_LIMIT} Reached
	#Exit Codes:	1=Wrong parameters
function ss__hyperstoreSysPrep() {
	#Dependencies:	__getCursorPosition, __getMenuInput, __getYesNoInput, __printDebugMessage, __printMessage, __printStatusMessage, __printTitle, ss__configureHyperStorePrerequisites, ss__updateSystem
	[[ ${#} -gt 1 ]] && __raiseWrongParametersError ${#} 0 1
	local -a _cursorPosition
	local _disk
	local _hyperstoreVersion="${1:-}"
	local -a _versions
	local IFS

	__printTitle 'Prepare HyperStore Appliance' 'This will download HyperStore files and helper scripts'
	if __downloadURI "${ss_versionsURL}" "$(__getDirectoryName)/versions.txt" 'Files List'; then
		_versions=($(awk 'BEGIN {FS=", "}; match($1, /^HyperStore-/) {sub("HyperStore-", "", $1); print $1}' "$(__getDirectoryName)/versions.txt" | sort -ruV))
		if [[ -z "${_hyperstoreVersion:-}" ]]; then
			__printMessage "${IWHITE}Which HyperStore version would you like to build for?"
			__getMenuInput 'HyperStore Version:' '_versions' '_hyperstoreVersion' '1' || return ${?}
			_hyperstoreVersion="${_versions[$(( ${_hyperstoreVersion} - 1 ))]}"
		fi
	else
		__printMessage "Failed to download the list of files, please transfer the Cloudian HyperStore Binary file manually to ${ss_STAGING_DIRECTORY}"
	fi

	if __isSourced; then
		__printDebugMessage "Sourced Mode::Preparing For: ${_hyperstoreVersion}"
	else
		__getYesNoInput 'Are you sure you want to continue?' 'Yes' || return 1
		__printDebugMessage "Preparing For: ${_hyperstoreVersion}"
		(( ! ss_REMOTE )) && __setClearScreenState 1
	fi

	ss__updateSystem || return ${?}

	__printMessage "Setting up Staging Directory (${IWHITE}${ss_STAGING_DIRECTORY}${RST}) ... " ${false}
	if __createDirectory "${ss_STAGING_DIRECTORY}" >/dev/null <<<'No'; then
		__printMessage "${IGREEN}Done"
	else
		__printMessage "${IRED}Failed"
		return 3
	fi

	if [[ -f "$(__getDirectoryName)/versions.txt" ]] && (__isSourced || __getYesNoInput 'Automatically download files?' 'Yes'); then
		if __isSourced || __getYesNoInput 'Will this node be the installation master?' 'Yes'; then
			if ss__hyperstoreSysPrepDownloader "$(__getDirectoryName)/versions.txt" "Script License HyperStore-${_hyperstoreVersion}"; then
				__removeFile "$(__getDirectoryName)/versions.txt" || return 5
			else
				__removeFile "$(__getDirectoryName)/versions.txt" || return 5
				return 6
			fi
		else
			if ss__hyperstoreSysPrepDownloader "$(__getDirectoryName)/versions.txt" 'Script License'; then
				__removeFile "$(__getDirectoryName)/versions.txt" || return 5
			else
				__removeFile "$(__getDirectoryName)/versions.txt" || return 5
				return 6
			fi
		fi
	else
		__printMessage 'Please copy files into the proper directories now ...'
		__pause
	fi

	ss__configureHyperStorePrerequisites ${true} || return ${?}

	if ! __isSourced && __getYesNoInput 'Would you like to prepare all additional disks for HyperStore FS usage?' 'Yes'; then
		__printMessage
		ss__configureDisks "$(lsblk --output NAME --nodeps --noheadings | sed -r -e ':a;N;$!ba;s~\n~ ~g')"
		__printMessage
		__printMessage "${IGREEN}Configure Disks Completed"
		__printMessage
	fi

	if ! __isSourced && __getYesNoInput 'Would you like to build an offline yum package cache?' 'Yes'; then
		__printMessage 'Performing package cleanup ... ' ${false}
		yum -q clean all >/dev/null 2>&1 || return 7
		__printMessage "${IGREEN}Done"

		__printMessage 'Building package cache ... ' ${false}
		yum -q makecache >/dev/null 2>&1 || return 8
		__printMessage "${IGREEN}Done"
	fi

	if ! __isSourced && __getYesNoInput 'Would you like to update SSHD to not use DNS reverse lookups at login?' 'Yes'; then
		__printMessage 'Updating /etc/ssh/sshd_config ... ' ${false}
		if grep -i -E -q '^#?UseDNS.*' /etc/ssh/sshd_config 2>/dev/null; then
			sed -i -r -e 's~#?UseDNS.*$~UseDNS no~i' /etc/ssh/sshd_config
		else
			echo 'UseDNS no' >>/etc/ssh/sshd_config
		fi
		__printMessage "${IGREEN}Done"
	fi

	__printMessage 'Creating /etc/issue file ... ' ${false}
	cat <<-EOF >/etc/issue
		[1;32mCloudian HyperStore Appliance${RST} built on [1;36m$(cat /etc/redhat-release 2>/dev/null)${RST}
		Kernel \r on an \m

		[1mIP Address: [32m0.0.0.0${RST}

	EOF
	__printMessage "${IGREEN}Done"

	__printMessage 'Creating /sbin/ifup-local script ... ' ${false}
	cat <<-'EOF' >/sbin/ifup-local
		#!/bin/bash

		if [[ "${1:-}" != "lo" ]]; then
		    sed -i -r 's~^.*IP Address:.*$~'"$(tput bold)"'IP Address: '"$(tput setaf 2)$(hostname -I)$(tput sgr0)"'~' /etc/issue
		    sed -i -r "s~^[^\s]+(\s+\b$(hostname -s)(\.$(hostname -d 2>/dev/null || sysctl -n kernel.domainname))?\b.*$)~$(hostname -I | awk '{print $1}') \1~gI" /etc/hosts
		fi
	EOF
	__printMessage "${IGREEN}Done"
	chmod +x /sbin/ifup-local
	
	__printMessage 'Customizing prompt ... ' ${false}
	cat <<-'EOF' >/etc/profile.d/prompt.sh
		#!/bin/bash

		if [[ $(id -u) == 0 ]]; then
			PS1='\[\033[01;31m\]\h\[\033[01;36m\] \W \$\[\033[00m\] '
		else
			PS1='\[\033[01;32m\]\u@\h\[\033[01;36m\] \w \$\[\033[00m\] '
		fi
	EOF
	__printMessage "${IGREEN}Done"

	__printMessage 'All settings have been updated.'		

	return 0
}

#ss__hyperstoreSysPrepDownloader(DownloadsFileList, DownloadTypes, SaveLocation)
	#Used by ss__hyperstoreSysPrep to download files automatically
	#Return Codes:	0=Success
	#Exit Codes:	1=Wrong Parameters; 2=DownloadsFileList file does not exist
function ss__hyperstoreSysPrepDownloader() {
	#Dependencies:	__downloadURI, __printDebugMessage, __raiseError, __raiseWrongParametersError
	[[ ${#} -lt 2 || ${#} -gt 3 ]] && __raiseWrongParametersError ${#} 2 3
	local _downloadFileList="${1:?$(__raiseError 'DownloadsFileList is required')}"
	local _downloadType
	local -a _downloadTypes=(${2:?$(__raiseError 'DownloadTypes is required')})
	local _displayName _fileLocation _fileName _filePermissions _fileURL
	local _pydioDownloadURL='https://www.cloudian.info/pydio/public/'
	local _ftpDownloadURL='ftp://commedftp:8eC25gBe@ftp.cloudian.com/'
	local _saveLocation="${3:-}"

	[[ ! -f "${_downloadFileList}" ]] && __raiseError "File ${_downloadFileList} does not exist and cannot be parsed for files to download."
	[[ -n "${_saveLocation:-}" && ! -d "${_saveLocation:-}" ]] && __createDirectory "${_saveLocation}"

	__printDebugMessage "Download Types: ${_downloadTypes[*]}"
	for _downloadType in ${_downloadTypes[*]}; do
		__printDebugMessage "	Download Type: ${_downloadType}"
		for _fileName in $(awk -v _downloadType="${_downloadType}" 'BEGIN {FS=", "}; {if ($1 == _downloadType) print $4};' "${_downloadFileList}"); do
			_displayName="$(awk -v _downloadType="${_downloadType}" -v _fileName="${_fileName}" 'BEGIN {FS=", "}; {if ($1 == _downloadType && $4 == _fileName) print $2};' "${_downloadFileList}")"
			_fileLocation="$(awk -v _downloadType="${_downloadType}" -v _fileName="${_fileName}" 'BEGIN {FS=", "}; {if ($1 == _downloadType && $4 == _fileName) print $3};' "${_downloadFileList}")"
			_filePermissions="$(awk -v _downloadType="${_downloadType}" -v _fileName="${_fileName}" 'BEGIN {FS=", "}; {if ($1 == _downloadType && $4 == _fileName) print $5};' "${_downloadFileList}")"
			_fileURL="$(awk -v _downloadType="${_downloadType}" -v _fileName="${_fileName}" 'BEGIN {FS=", "}; {if ($1 == _downloadType && $4 == _fileName) print $6};' "${_downloadFileList}")"
			_fileURL="${_fileURL/$'\r'}" #Remove carriage returns if someone saved the file in Windows format instead of *nix format

			[[ -n "${_saveLocation:-}" ]] && _fileLocation="${_saveLocation}" || _fileLocation="${_fileLocation//--staging-directory--/${ss_STAGING_DIRECTORY}}"

			__printDebugMessage "_displayName=>${_displayName}"
			__printDebugMessage "_fileName=>${_fileName}"
			__printDebugMessage "_fileURL=>${_fileURL}"
			__printDebugMessage "_fileLocation=>${_fileLocation}"
			__printDebugMessage "_filePermissions=>${_filePermissions}"

			[[ "${_fileURL}" != "${_fileURL/--pydio--/}" ]] && _fileURL="${_fileURL/--pydio--/--pydio-url--}/dl/--filename--"
			_fileURL="${_fileURL/--ftp--/${_ftpDownloadURL}}"
			_fileURL="${_fileURL/--pydio-url--/${_pydioDownloadURL}}"
			_fileURL="${_fileURL//--filename--/${_fileName}}"

			__printDebugMessage "After Replacements::_fileURL=>${_fileURL}"

			[[ ! -d "${_fileLocation}" ]] && __createDirectory "${_fileLocation}" && __printMessage
			if [[ ! -f "${_fileLocation}/${_fileName}" ]] && __downloadURI "${_fileURL}" "${_fileLocation}/${_fileName}" "${_displayName}"; then
				chmod "${_filePermissions}" "${_fileLocation}/${_fileName}"
			fi

			unset _displayName _fileLocation _fileName _filePermissions _fileURL
		done
	done

	return 0
}

#ss__hyperstoreVMPrep(Hypervisor=[prompt], HyperStoreVersion=[prompt], SysPrep=${true})
	#Prepares current virtual machine for HyperStore deployment
	#If Hypervisor or HyperStoreVersion is not supplied a prompt will be presented to pick the desired build release
	#Return Codes:	0=Success
function ss__hyperstoreVMPrep() {
	[[ ${#} -gt 3 ]] && __raiseWrongParametersError ${#} 0 3
	local -a _cursorPosition
	local _hyperstoreVersion="${2:-}"
	local _hypervisor="${1:-}"
	local -a _hypervisors=('Hyper-V' 'Other' 'VirtualBox' 'VMware')
	local -i _sysPrep=${3:-${true}}

	if [[ -z "${_hypervisor:-}" ]]; then
		__getMultipleChoiceInput 'Which Hypervisor do you want to configure for?' '_hypervisors' '_hypervisor' 'VMware' || return ${?}
	fi

	if [[ -f "$(__getDirectoryName)/$(__getFileName).resume" ]] || (( ${_sysPrep} )); then
		if [[ -f "$(__getDirectoryName)/$(__getFileName).resume" ]]; then
			__printMessage 'Resuming VM Prep After Reboot ... '
			__pause
			[[ ! -f "$(__getDirectoryName)/$(__getFileName).resume" ]] && exit 0
			ss__disableAutoResume
			__disableAutoLogin
		else
			ss__hyperstoreSysPrep "${_hyperstoreVersion}" || return ${?}
			if (( ${ss_REBOOT} )); then
				__printMessage 'Need to reboot since a new kernel was installed.'
				__printMessage 'This script will automatically resume after rebooting.'
				ss__enableAutoResume "--vm-prep ${_hypervisor} ${_hyperstoreVersion}"
				__enableAutoLogin
				__reboot
			fi
		fi
	fi

	case "${_hypervisor}" in
		'Hyper-V')
			__printMessage 'Automatic Hyper-V guest tools installation is not available in this release'
			__printMessage 'Please install manually now before continuing.'
			__pause
			__printMessage
		;;
		'VirtualBox')
			__printMessage 'Getting list of files to download ... ' ${false}
			if __downloadURI "${ss_versionsURL}" "$(__getDirectoryName)/versions.txt" 'Files List'; then
				__printMessage 'Installing VirtualBox Guest Editions ... ' ${false}
				_cursorPosition=($(__getCursorPosition))
				__printMessage
				__installPackage 'dkms perl gcc make kernel-devel'
				ss__hyperstoreSysPrepDownloader "$(__getDirectoryName)/versions.txt" "HyperVisor-VirtualBox"

				__createDirectory "$(__getDirectoryName)/iso"
				mount -o loop "$(awk 'BEGIN {FS=", "}; {if ($1 == "HyperVisor-VirtualBox") print $3"/"$4};' "$(__getDirectoryName)/versions.txt")" "$(__getDirectoryName)/iso/"
				"$(__getDirectoryName)/iso/VBoxLinuxAdditions.run" --nox11
				umount "$(__getDirectoryName)/iso"
				__removeDirectory "$(__getDirectoryName)/iso"
				__removeFile "$(awk 'BEGIN {FS=", "}; {if ($1=="HyperVisor-VirtualBox") print $3"/"$4};' "$(__getDirectoryName)/versions.txt")"
				__removeFile "$(__getDirectoryName)/versions.txt"
				__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done"
			else
				__printMessage "${IRED}Failed"
				__printMessage
				__printMessage 'Because the list of files to download failed, automatic guest tools cannot be installed.'
				if __getYesNoInput 'Would you like to proceed with manual guest tool installation?' 'Yes'; then
					__printMessage 'Please install manually before continuing.'
					__pause
					__printMessage
				else
					return 1
				fi
			fi
		;;
		'VMware')
			if ! __checkInstalledPackage 'open-vm-tools'; then
				__printMessage 'Installing VMware VM Guest Tools ... '
				if ! __installPackage 'open-vm-tools'; then
					__printMessage 'Automatic installation failed, please try again manually.'
					__pause
				fi
			fi
		;;
		*)
			__printMessage 'Please install any guest tools you need manually'
			__pause
			__printMessage
		;;
	esac

	__printMessage 'Creating /etc/issue file ... ' ${false}
	cat <<-EOF > /etc/issue
		[1;32mCloudian HyperStore Virtual Appliance${RST} built on [1;36m$(cat /etc/redhat-release 2>/dev/null)${RST}
		Kernel \r on an \m

		By default SSH is enabled and you can login with the
		default appliance username/password.

		[1mIP Address: [1;32m0.0.0.0${RST}

	EOF
	__printMessage "${IGREEN}Done"

	return 0
}

#ss__installBundledPackages()
	#Installs all rpm pages that are bundled inside the selfextract_prereq.bin file
	#Return Codes:	0=Successfully Installed; 1=selfextract_prereq.bin not found; 2=ss__extractPackagedFile failed
	#Exit Codes:
function ss__installBundledPackages() {
	local _extension
	local _fileName
	local _fileURI
	local _hyperstoreBinaryFile="$(ss__printNewestHyperStoreBinaryVersion)"
	local _selfExtractBundle="${ss_STAGING_DIRECTORY}/selfextract_prereq.bin"
	local _tempDirectory="$(mktemp --directory --tmpdir)"

	if [[ ! -f "${_selfExtractBundle}" && -f "${_hyperstoreBinaryFile}" ]]; then
		tail -n+$(awk '/^__ARCHIVE_BELOW__/ {print NR + 1; exit 0; }' "${_hyperstoreBinaryFile}") "${_hyperstoreBinaryFile}" | tar -xOz ./cloudian-*.tar.gz | tar -xz -C "${ss_STAGING_DIRECTORY}" selfextract_prereq.bin || return 1
	fi

	if [[ -f "${_selfExtractBundle}" ]]; then
		__printMessage "Extracting Bundled Packages ... " ${false}
		ss__extractPackagedFile '*' "${_tempDirectory}" && __printMessage "${IGREEN}Done" || { __printMessage "${IRED}Failed (${?})"; return 2; }
		__printMessage

		for _fileURI in "${_tempDirectory}"/*; do
			_extension="${_fileURI##*.}"
			_fileName="${_fileURI##*/}"

			if [[ "${_fileName,,}" =~ ^puppet.*$ ]]; then
				__printMessage "${IYELLOW}Skipped ${RST}'${IWHITE}${_fileName}${RST}'"
			else
				case "${_extension,,}" in
					'repo')
						__createDirectory "/etc/yum.repos.d" >/dev/null
						__printMessage "Adding Repo '${IWHITE}${_fileName}${RST}' to '${IWHITE}/etc/yum.repos.d/${RST}'"
						mv "${_fileURI}" /etc/yum.repos.d/
						;;
					'rpm')
						__installRPM "${_fileURI}" || __printMessage "Return Code: ${?}"
						__removeFile "${_fileURI}" >/dev/null
						;;
					*) __printErrorMessage "Unknown file extension: ${_fileURI##*.}" ;;
				esac
			fi
		done
		__removeDirectory "${_tempDirectory}" ${true} >/dev/null
	else
		__printErrorMessage "Unable to locate selfextract_prereq.bin or Cloudian HyperStore Binary File in ${ss_STAGING_DIRECTORY}."
		return 1
	fi

	return 0
}

#ss__installPackage(PackageName)
	#If not already installed, attempt to install PackageName from bundle or prompt to install from network repositories
	#Return Codes:	0=Successfully Installed; 1=Failed to install
function ss__installPackage() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _packageName="${1:?$(__raiseError 'PackageName is required')}"

	if ! __checkInstalledPackage "${_packageName}"; then
		if ss__extractPackagedFile "${_packageName}" "$(__getDirectoryName)" && __installRPM "$(__getDirectoryName)/${_packageName}*"; then
			__removeFile "$(__getDirectoryName)/${_packageName}*" || :
		else
			if __getYesNoInput 'Would you like to try installing from network repositories?' 'Yes'; then
				__installPackage "${_packageName}" || return 1
			else
				return 1
			fi
		fi
	fi

	return 0
}

#ss__installSSHKeyFile(SSHKeyFileFullPath, ClusterPassword="")
	#Will install an SSH key file on nodes in survey file
	#If no ClusterPassword is supplied, will prompt for one unless a SSH key file is found
	#Return Codes:	0=Success; 1=No SSH Key File
	#Exit Codes:
function ss__installSSHKeyFile() {
	[[ ${#} -lt 1 || ${#} -gt 2 ]] && __raiseWrongParametersError ${#} 1 2
	local _clusterPassword="${2:-}"
	local _sshKeyFile="${1:?$(__raiseError 'SSHKeyFileFullPath is required')}"
	local _sshCommand

	_sshKeyFile="${_sshKeyFile/#\~/${HOME}}"

	if [[ "${_sshKeyFile}" != "$(ss__getSSHKeyFileName)" && -f "$(ss__getSSHKeyFileName)" ]]; then
		__printMessage "Using SSH Key: $(ss__getSSHKeyFileName)"
	elif [[ -z "${_clusterPassword}" ]]; then
		__logMessage 'No SSH Key File'
		__printMessage "If your ${USER} password is the same on all (or most) nodes in the cluster, you can supply it as a cluster password"
		__printMessage 'If you do not want to supply a password, each server will prompt for one when connecting.'
		__printMessage
		__getInput 'Cluster Password:' '_clusterPassword' '' ${true} || break
	fi

	[[ ! -f "${_sshKeyFile}" ]] && ss__generateSSHKeyFile "${_sshKeyFile}"

	_sshCommand=$(ss__printInstallSSHKeyFileCommand "${_sshKeyFile}")
	_sshCommand+='exit 0'

	ss__runOnCluster "${_sshCommand}" "${_clusterPassword:-}" ${true} || return ${?}

	return 0
}

#ss__isCurrentPasswordSimple()
	#Checks if the current users has a simple to guess or Cloudian default password
	#Return Code:	0=Yes; 1=No; 2=Cannot read /etc/shadow; 3=Python error
function ss__isCurrentPasswordSimple() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0
	local IFS
	local -a _shadowPassword
	local _testPassword
	local _testPasswordHash

	IFS='$'
	_shadowPassword=($(awk -v _user="${USER}" 'BEGIN {FS=":"}; {if($1 == _user) {print $2}; }' /etc/shadow 2>/dev/null)) || return 2
	unset IFS

	[[ ${#_shadowPassword[@]} -lt 4 ]] && return 2

	__printDebugMessage "Shadow Password: ${_shadowPassword[*]:-unset}" ${true} 2
	__printDebugMessage "        Hash ID: ${_shadowPassword[1]:-unset}" ${true} 2
	__printDebugMessage "           Salt: ${_shadowPassword[2]:-unset}" ${true} 2
	__printDebugMessage "Hashed Password: ${_shadowPassword[3]:-unset}" ${true} 2
	__printDebugMessage

	for _testPassword in "${RESTRICTED_PASSWORDS[@]}"; do
		__printDebugMessage "Testing Password: ${_testPassword}" ${true} 2
		_testPasswordHash="$(python -c "import crypt; print crypt.crypt('${_testPassword}', '\$${_shadowPassword[1]:-}\$%s\$' % '${_shadowPassword[2]:-}')" 2>/dev/null)" || return 3
		__printDebugMessage "          Hashed: ${_testPasswordHash}" ${true} 2

		[[ "${_testPasswordHash##*$}" == "${_shadowPassword[3]:-}" ]] && return 0
	done

	return 1
}

#ss__onlineUpdate(Relaunch=true, Url=${ss_uri})
	#Downloads latest version of this script from the internet
	#	If Relaunch is true then the downloaded script will be launched
	#Return Codes:	0=Success; 1=Failed Updating
function ss__onlineUpdate() {
	[[ ${#} -gt 2 ]] && __raiseWrongParametersError ${#} 0 2
	local -i _relaunch=${1:-${true}}
	local _url="${2:-${ss_uri}}"

	__isBeta && [[ "${_url}" == "${ss_uri}" ]] && _url="${ss_uri_beta}"
	__printDebugMessage "URL: '${_url}'"

	while ! __downloadURI "${_url}" "$(__getDirectoryName)/$(__getFileName)" 'System Configuration Script'; do
		__getYesNoInput 'Would you like to try again?' || return 1
	done

	__printMessage "${IWHITE}Updating Settings ... " ${false}
	ss__saveSettings
	ss_UPDATED=${true}
	ss__saveSetting 'ss_UPDATED'
	__printMessage "${IGREEN}Done"

	if (( _relaunch )); then
		trap - EXIT
		trap - SIGINT
		trap - SIGTSTP

		if __isDebugEnabled; then
			exec "$(__getDirectoryName)/$(__getFileName)" --debug $((( ss_REMOTE )) && printf '%s' '--remote')
		else
			exec "$(__getDirectoryName)/$(__getFileName)" $((( ss_REMOTE )) && printf '%s' '--remote')
		fi
	fi

	return 0
}

#ss__parseArguments(arguments...)
	#Parses command line arguments
	#Return Codes:	0=Success; 1=Failed Parsing
	#Exit Codes:	<depends on options>
function ss__parseArguments() {
	local _arguments=" ${@} "

	#Change short opts to long opts
	_arguments="${_arguments// -A / --add-entry }"
	_arguments="${_arguments// -a / --auto-update }"
	_arguments="${_arguments// -c / --color }"
	_arguments="${_arguments// -d / --debug }"
	_arguments="${_arguments// -F / --func-list }"
	_arguments="${_arguments// -f / --func-usage }"
	_arguments="${_arguments// -h / --help }"
	_arguments="${_arguments// -p / --prerequisites }"
	_arguments="${_arguments// -r / --remote }"
	_arguments="${_arguments// -u / --update }"
	_arguments="${_arguments// -v / --version }"
	_arguments="${_arguments// -w / --wipe }"

	#arguments are not processed in the order they are passed
	#instead they are searched for and acted upon in the order listed below
	#doing this ensures things like debugging can be turned on early
	#and options like --help or --version can be displayed regardless of other options supplied

	#These arguments will set variables/values and continue
	[[ "${_arguments}" != "${_arguments// --debug }" ]] && {
		_arguments="${_arguments// --debug}"
		DEBUG=${true}
	}
	[[ "${_arguments}" != "${_arguments// --beta }" ]] && {
		__printDebugMessage "Forced Beta Mode (Was: ${VERSION_STATE})"
		_arguments="${_arguments// --beta}"
		VERSION_STATE='beta'
		__printDebugMessage "Version State: '${VERSION_STATE}'"
	}
	[[ "${_arguments}" != "${_arguments// --no-beta }" ]] && {
		__printDebugMessage "Forced Non-Beta Mode (Was: ${VERSION_STATE})"
		_arguments="${_arguments// --no-beta}"
		VERSION_STATE=''
		__printDebugMessage "Version State: '${VERSION_STATE}'"
	}
	[[ "${_arguments}" != "${_arguments// --auto-update }" ]] && {
		_arguments="${_arguments// --auto-update}"
		ss_AUTO_UPDATE=${true}
	}
	[[ "${_arguments}" != "${_arguments// --no-update }" ]] && {
		_arguments="${_arguments// --no-update}"
		ss_AUTO_UPDATE=${false}
	}
	[[ "${_arguments}" != "${_arguments// --color }" ]] && {
		_arguments="${_arguments// --color}"
		ss_USE_COLORS=${true}
		__loadColors
	}
	[[ "${_arguments}" != "${_arguments// --no-color }" ]] && {
		_arguments="${_arguments// --no-color}"
		ss_USE_COLORS=${false}
		__unloadColors
	}
	[[ "${_arguments}" != "${_arguments// --remote }" ]] && {
		_arguments="${_arguments// --remote}"
		ss_REMOTE=${true}
		BREADCRUMBS[0]="${BREADCRUMBS[0]} ($(hostname -s))"
	}

	#These arguments will all exit the script
	[[ "${_arguments}" != "${_arguments// --help }" ]] && {
		__printMessage "${IGREEN}$(ss__printASCIILogo)"
		__printMessage
		ss__printCopyright
		__printMessage
		ss__printUsage ${true}
		exit ${?}
	}
	[[ "${_arguments}" != "${_arguments// --version }" ]] && {
		__printDebugMessage "Version State: '${VERSION_STATE}'"
		__printMessage "${IGREEN}$(ss__printASCIILogo)"
		__printMessage
		ss__printCopyright
		__printDebugMessage "Version State: '${VERSION_STATE}'"
		exit ${?}
	}

	[[ "${_arguments}" != "${_arguments#* --add-entry }" ]] && {
		ss__getSurveyFileEntryInputs ${true} || __printMessage
		exit 0
	}
	[[ "${_arguments}" != "${_arguments#* --configure-disks }" ]] && {
		_arguments="${_arguments/#* --configure-disks}"
		_arguments="${_arguments/% --*}"
		if [[ -n "${_arguments// /}" ]]; then
			__printTitle 'Setup Disks' "Auto Configuring Disks: '$(__trim "${_arguments}")'"
			if __getYesNoInput "${IRED}This will erase everything on these disks.${RST}\nAre you sure you want to continue?" "${IRED}No"; then
				ss__configureDisks "$(__trim "${_arguments}")"
			fi
		else
			__printErrorMessage "Please specify the disks to configure"
		fi
		exit 0
	}
	[[ "${_arguments}" != "${_arguments// --delete-networking }" ]] && {
		if __getYesNoInput 'Are you sure you want to delete all network interface configuration files?' "${IRED}No"; then
			rm -fv "${SYSCONFIG_NETWORK_SCRIPTS}"/ifcfg-*
			ss__createNetworkConfig 'lo' 'loopback' 2>&1 >/dev/null
		fi
		exit ${?}
	}
	[[ "${_arguments}" != "${_arguments#* --embed-file }" ]] && {
		_arguments="${_arguments/#* --embed-file}"
		_arguments="${_arguments/% --*}"
		_arguments="$(__trim "${_arguments}")"

		if [[ -n "${_arguments// /}"  && -f "${_arguments}" ]]; then
			__printMessage "Preparing: '${IYELLOW}${_arguments}${RST}'"

			tar -czf "${_arguments}.tgz" "${_arguments}" || __printErrorMessage "Failed to compress ${_arguments}" ${true} 2
			base64 --wrap=0 "${_arguments}.tgz" > "${_arguments}.tgz.b64" || __printErrorMessage "Failed to encode ${_arguments}" ${true} 3

			__removeFile "${_arguments}.tgz"
			__printMessage "File ${_arguments} has been prepared for embedding as ${_arguments}.tgz.b64"
			md5sum "${_arguments}" > "${_arguments}.md5"
			cat "${_arguments}.md5"
		else
			__printErrorMessage 'Please specify a file to prepare for embedding.' ${true} 1
		fi

		exit 0
	}
	[[ "${_arguments}" != "${_arguments// --func-list }" ]] && {
		declare -F | sed 's~declare -f~function~gi' | less -X -F
		exit ${?}
	}
	[[ "${_arguments}" != "${_arguments#* --func-usage }" ]] && {
		_arguments="${_arguments/#* --func-usage}"
		_arguments="${_arguments/% --*}"
		if [[ -n "${_arguments// /}" ]]; then
			__printFunctionUsage '' '' '' "${_arguments// /}"
		else
			__printMessage 'Please specify a function name to get usage information.'
		fi
		exit 0
	}
	[[ "${_arguments}" != "${_arguments// --ge }" ]] && {
		_arguments="${_arguments/#* --ge}" #Remove everything before --ge
		_arguments="${_arguments/% --*}" #Remove everything after next --* argument
		ss__createMountBindPoint ${_arguments} #Disk, MountPoint
		exit ${?}
	}
	[[ "${_arguments}" != "${_arguments#* --ova-prep }" ]] && {
		_arguments="${_arguments/#* --ova-prep}"
		_arguments="${_arguments/% --*}"
		ss__hyperStoreOVAPrep ${_arguments}
		exit ${?}
	}
	[[ "${_arguments}" != "${_arguments// --preInstallCheck }" ]] && {
		ss__menu_preInstallCheck false
		exit 0
	}
	[[ "${_arguments}" != "${_arguments// --prerequisites }" ]] && {
		ss__configureHyperStorePrerequisites ${true}
		if (( ss_REMOTE )); then
			__printMessage
			__printMessage "Completed Prerequisites on $(__getHostname)"
			__pause
		fi
		exit ${?}
	}
	[[ "${_arguments}" != "${_arguments#* --resize-disk }" ]] && {
		_arguments="${_arguments/#* --resize-disk}"
		_arguments="${_arguments/% --*}"
		_arguments="$(__trim "${_arguments}")"

		if [[ -n "${_arguments// /}" && -b "${_arguments// /}" ]]; then
			__printMessage "Resizing: '${IYELLOW}${_arguments}${RST}'"
			ss__resizePartition "${_arguments}"
		else
			__printErrorMessage 'Please specify a partition to resize.' ${true} 1
		fi

		exit 0
	}
	[[ "${_arguments}" != "${_arguments#* --sys-prep }" ]] && {
		_arguments="${_arguments/#* --sys-prep}"
		_arguments="${_arguments/% --*}"
		if [[ -n "${_arguments// /}" ]]; then
			ss__hyperstoreSysPrep "$(__trim "${_arguments}")"
		else
			ss__hyperstoreSysPrep
		fi
		exit ${?}
	}
	[[ "${_arguments}" != "${_arguments// --update }" ]] && {
		_arguments="${_arguments/#* --update }"
		_arguments="$(__trim "${_arguments/% --*} ")"
		[[ -n "${_arguments:-}" ]] && __printDebugMessage "Arguments: '${_arguments:-}'" && ss_uri="${_arguments}"
		ss__onlineUpdate ${false}
		exit ${?}
	}
	[[ "${_arguments}" != "${_arguments#* --vm-prep }" ]] && {
		_arguments="${_arguments/#* --vm-prep}"
		_arguments="${_arguments/% --*}"
		ss__hyperstoreVMPrep ${_arguments}
		exit ${?}
	}
	[[ "${_arguments}" != "${_arguments#* --wipe }" ]] && {
		ss__cleanupInstallation
		exit ${?}
	}

	if [[ -n "${_arguments// /}" ]]; then
		__printMessage "$(__getFileName): unrecognized option '$(__trim "${_arguments}")'"
		ss__printUsage
		exit 1
	fi

	#If we made it this far, we are in interactive mode and parsed all arguments
	return 0
}

#ss__partitionDisk(Disk)
	#Creates a single partition on Disk
		#If SilentOutput is true, no output will be displayed
	#Return Codes:	0=Success; 1=Failed partition create
function ss__partitionDisk() {
	[[ ${#} -lt 1 || ${#} -gt 2 ]] && __raiseWrongParametersError ${#} 1 2
	local -a _cursorPosition
	local _disk="${1:?$(__raiseError 'Disk is required')}"
	local IFS

	[[ ! -b "${_disk}" ]] && __raiseError "${_disk} is not a valid block device"

	__printMessage "Partitioning ${_disk} ... " ${false}; _cursorPosition=($(__getCursorPosition)); __printMessage

	#Create a new partition
	if sgdisk -n 1:1M "${_disk}" >/dev/null 2>&1; then
		__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done"
		return 0
	else
		__printStatusMessage ${_cursorPosition[*]} "${IRED}Failed"
		return 1
	fi
}

#ss__printASCIILogo(Product=${false})
	#Prints out the Cloudian name in basic ASCII characters
		#if product is set to true, it will also print out HyperStore below Cloudian
function ss__printASCIILogo() {
	[[ ${#} -gt 1 ]] && __raiseWrongParametersError ${#} 0 1

	cat <<-"EOF"
	   ____ _                 _ _
	  / ___| | ___  _   _  __| (_) __ _ _ __  ®
	 | |   | |/ _ \| | | |/ _` | |/ _` | '_ \
	 | |___| | (_) | |_| | (_| | | (_| | | | |
	  \____|_|\___/ \__,_|\__,_|_|\__,_|_| |_|
	EOF
	[[ "${1:-false}" == "true" ]] && cat <<-"EOF"
	     _   _                       ____  _
	    | | | |_   _ _ __   ___ _ __/ ___|| |_ ___  _ __ ___  ®
	    | |_| | | | | '_ \ / _ \ '__\___ \| __/ _ \| '__/ _ \
	    |  _  | |_| | |_) |  __/ |   ___) | |_ (_) | | |  __/
	    |_| |_|\__, | .__/ \___|_|  |____/ \__\___/|_|  \___|
	           |___/|_|
	EOF

	return 0
}

#ss__printCopyright()
	#Prints copyright information
function ss__printCopyright() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	fold -sw $(tput cols) <<-EOF
		${IWHITE}Thank you for using ${IGREEN}$(__getFileName)${RST}
		${IWHITE}Version: ${IGREEN}$(__getVersion)${RST}
	EOF
}

#ss__printInstallSSHKeyFileCommand(SSHKeyFileFullPath, SilentOutput=${false})
	#Prints out the command usable with ss__runOnCluster for installing the local SSH Key File
	#Return Codes:	0=Success
	#Exit Codes:
function ss__printInstallSSHKeyFileCommand() {
	[[ ${#} -lt 1 || ${#} -gt 2 ]] && __raiseWrongParametersError ${#} 1 2
	local _silentOutput="${2:-${false}}"
	local _sshKeyFile="${1:?$(__raiseError 'SSHKeyFileFullPath is required')}"

	_sshKeyFile="${_sshKeyFile/#\~/${HOME}}"
	if [[ ! -f "${_sshKeyFile}" ]]; then
		if (( ${_silentOutput} )); then
			ss__generateSSHKeyFile "${_sshKeyFile}" 2>&1 >/dev/null
		else
			ss__generateSSHKeyFile "${_sshKeyFile}" >&2
		fi
	fi

	cat <<-EOF
		umask 077

		if _sshd=\$(which sshd) && [[ -f "\${_sshd:-}" ]]; then
			_keyFile="\$(\${_sshd} -T 2>/dev/null | awk '{if(tolower(\$1) == "authorizedkeysfile") print \$2}' || :)"
		fi

		[[ -z "\${_keyFile:-}" ]] && _keyFile="~/.ssh/authorized_keys"
		_keyFile="\${_keyFile/#\~/\${HOME}}"
		[[ "\${_keyFile:0:1}" != '/' ]] && _keyFile="\${HOME}/\${_keyFile}"

		_sshKey="$(cat "${_sshKeyFile}.pub")"
		_sshKey="\${_sshKey#"\${_sshKey%%[![:space:]]*}"}"
		_sshKey="\${_sshKey%"\${_sshKey##*[![:space:]]}"}"

		(( ! ${_silentOutput} )) && (( ${DEBUG} )) && echo "DEBUG: _keyFile='\${_keyFile}'"
		(( ! ${_silentOutput} )) && (( ${DEBUG} )) && echo "DEBUG: _sshKey='\${_sshKey}'"
		(( ! ${_silentOutput} )) && (( ${DEBUG} )) && echo "DEBUG: Local Hostname='\$(hostname -s)'"
		(( ! ${_silentOutput} )) && (( ${DEBUG} )) && echo "DEBUG: Requesting (Remote) Hostname='$(hostname -s)'"

		[[ ! -d "\$(dirname "\${_keyFile}")" ]] && mkdir -p "\$(dirname "\${_keyFile}")"

		[[ \$(grep -c "\${_sshKey#* }" "\${_keyFile}" 2>/dev/null) -gt 1 ]] && sed -i -e "\~^\${_sshKey}.*\$~d" "\${_keyFile}"
		if grep -q "\${_sshKey#* }" "\${_keyFile}" 2>/dev/null; then
			(( ! ${_silentOutput} )) && echo "Already Installed"
		else
			printf '%s Cloudian@%s\n' "\${_sshKey}" "$(hostname -s)" >> "\${_keyFile}"
			(( ! ${_silentOutput} )) && echo "Adding SSH Key to '\${_keyFile}'"
		fi; 
	EOF
}

#ss__printInvalidSurveyFileEntries()
	#Prints invalid entries found inside the survey file
	#Return Codes:	0=Success
	#Exit Codes:	1=Invalid Parameters
function ss__printInvalidSurveyFileEntries() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	grep -v -E "${ss_SURVEY_INVALID_REGEX}" "$(ss__getSurveyFileName)" 2>/dev/null || __printMessage 'No Invalid Entries Found'

	return 0
}

#ss__printNewestHyperStoreBinaryVersion(Directory=${ss_STAGING_DIRECTORY})
	#Prints newest HyperStoreBinary file version from ${Directory}
	#Return Codes:	0=Success; 1=Directory does not exist
	#Exit Codes:	1=Wrong parameters
function ss__printNewestHyperStoreBinaryVersion() {
	#Dependencies:	__raiseWrongParametersError
	[[ ${#} -gt 1 ]] && __raiseWrongParametersError ${#} 0 1
	local _directory="${1:-${ss_STAGING_DIRECTORY}}"
	local IFS
	local -a _versions

	[[ ! -d "${_directory}" ]] && return 1

	_versions=("${_directory}"/CloudianHyperStore-*.bin)
	__logMessage "Found Versions: ${_versions[@]}"

	_versions=($(IFS=$'\n'; sort -ruV <<<"${_versions[*]}"; unset IFS))
	__logMessage "Sorted Versions: ${_versions[@]}"

	printf '%s' "${_versions[0]}"

	return 0
}

#ss__printSurveyFileEntries(PrintDisabledEntries=${false})
	#Prints the entries in the ss_SURVEY_FILE in a table format
	#Return Codes:	0=Success; 1=No Entries
function ss__printSurveyFileEntries() {
	[[ ${#} -gt 1 ]] && __raiseWrongParametersError ${#} 0 1
	local _line
	local -i _lineNumber=0
	local -i _printDisabledEntries=${1:-${false}}

	while read _line; do
		(( ++_lineNumber ))
		if [[ ${_lineNumber} -eq 1 ]]; then
			__printMessage "${IWHITE}${UNDR}${_line}"
			__isColorsLoaded || {
				printf -v line '%*s' $(__removeEscapeCodes "${_line}" | wc -m)
				printf '%s\n' "${line// /-}"
			}
		elif [[ "${_line:0:1}" == '#' ]]; then
			__printMessage "${IRED}${_line}"
		else
			__printMessage "${IGREEN}${_line}"
		fi
	done < <(ss__getSurveyFileEntries "all" ${_printDisabledEntries} ${true} | column -t -s '	' 2>/dev/null)

	__printDebugMessage "_lineNumber = ${_lineNumber}"
	(( _lineNumber )) || return 1

	if (( _printDisabledEntries )); then
		__printMessage
		if __isColorsLoaded; then
			__printMessage "${IWHITE}Lines in ${IRED}red${IWHITE} are commented out in the survey file."
		else
			__printMessage "Regions that begin with '#' are commented out in the survey file."
		fi
	fi

	return 0
}

#ss__printUsage(FullDetails=${false})
	#Prints out usage information
	#If FullDetails is true, will display full details
function ss__printUsage() {
	[[ ${#} -gt 1 ]] && __raiseWrongParametersError ${#} 0 1
	local -i _fullDetails="${1:-${false}}"

	if (( ${_fullDetails} )); then
		fold -sw $(tput cols) <<-EOF
			Usage: $(__getFileName) [option]...

			-h, --help                     Prints this information
			-v, --version                  Prints version information

			-F, --func-list                Prints the names of all functions in this script
			-f, --func-usage               Prints the function definition for the given function name
			                                 * List all function names with --func-list

			-A, --add-entry                Add survey file entry
			-a, --auto-update              Attempts to auto update the script before running
			    --no-update                Skips auto updating the script before running
			    --configure-disks          Prepare disks specified in space separated list
			-c, --color                    Enables color output
			    --no-color                 Disable color output
			-d, --debug                    Turns on debugging output
			    --embed-file               Prepare file for being embedded into a script
			    --preInstallCheck          Enable preInstallCheck menu only
			    --prerequisites            Performs HyperStore Prerequisites Checks
			    --resize-disk <partition>  Will resize specified partition to 100% of disk available space.
			                                 * Only applies to disks that have been resized.
			-r, --remote                   Remote automation command
			-u, --update [<url>]           Update script and exit
			-w, --wipe                     Perform Cloudian Installation Cleanup

			    --ova-prep                 Ensures everything is set for this machine to be exported to OVA
			    --sys-prep                 Prepares system to become a HyperStore node
			    --vm-prep                  Prepares a virtual machine to become a HyperStore Node

		EOF
	else
		__printMessage "Usage: $(__getFileName) [OPTION]..."
		__printMessage "Try '$(__getFileName) --help' for more information."
	fi
}

#ss__removeDiskMounts(Disk)
	#Removes all mount entries for Disk from FSTAB and fslist.txt
	#Return Codes:	0=Success; 1=Invalid Disk; 2=System Disk; 3=Failed umount; 4=Failed mountpoint removal
function ss__removeDiskMounts() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _disk="/dev/${1:?$(__raiseError 'Disk is required')}"; _disk="${_disk//\/\///}"; _disk="${_disk//\/dev\/dev\///dev/}"
	local -i _fd _returnCode=0
	local IFS
	local -a _mounts
	local _devName _mountpoint _uuid

	[[ ! -b "${_disk}" ]] && return 1

	__logMessage "Removing Disk Mounts: ${_disk}"

	exec {_fd}<"${FSTAB}"
	(
		flock --exclusive ${_fd} #Get exclusive access to FSTAB

		_mounts=($(lsblk --noheadings --output MOUNTPOINT "${_disk}" 2>/dev/null || :))

		if [[ ${#_mounts[*]} -gt 0 ]]; then
			__logMessage "Disk: ${_disk}; Mount Count: ${#_mounts[@]}; Mount Points: '${_mounts[*]}'"
			if [[ " ${_mounts[*],,} " =~ \ (\/boot|\/|\[swap\])\  ]]; then
				__logMessage "Stopping Remove Disk Mounts: ${_disk}; System Used Disk"
				return 2
			fi
		fi

		while read _devName _uuid _mountpoint; do
			_devName="/dev/${_devName}"

			if [[ -n "${_mountpoint:-}" ]]; then #Clean based on mountpoint
				__logMessage "Disk: ${_disk}; Cleaning Mount: ${_mountpoint}"
				umount -f "${_mountpoint}" || return 3
				__removeDirectory "${_mountpoint}" || return 4
				sed -i -r -e "/^[^#].+\s${_mountpoint//\//\\/}\s.+$/d" "${FSTAB}"
				[[ -f "${ss_FSLIST}" ]] && sed -i -r -e "/^[^#].+\s${_mountpoint//\//\\/}$/d" "${ss_FSLIST}"
			fi

			if [[ -n "${_uuid:-}" ]]; then #Clean based on UUID
				__logMessage "Disk: ${_disk}; Cleaning UUID: ${_uuid}"
				sed -i -r -e "/^UUID=\"?${_uuid}\"?\s.+$/d" "${FSTAB}"
				[[ -f "${ss_FSLIST}" ]] && sed -i -r -e "/^UUID=\"?${_uuid}\"?\s.+$/d" "${ss_FSLIST}"
			fi

			if [[ -e "${_devName:-}" ]]; then #Clean based on deviceName
				__logMessage "Disk: ${_disk}; Cleaning Device Name: ${_devName}"
				sed -i -r -e "/^${_devName//\//\\/}\s.+$/d" "${FSTAB}"
				[[ -f "${ss_FSLIST}" ]] && sed -i -r -e "/^${_devName//\//\\/}\s.+$/d" "${ss_FSLIST}"
			fi
		done < <(lsblk --noheadings --output KNAME,UUID,MOUNTPOINT "${_disk}" 2>/dev/null || :)

		[[ -f "${ss_FSLIST}" ]] && sed -r -i -e '/^(STARTED|COMPLETED) .*$/d' "${ss_FSLIST}" #Remove STARTED/COMPLETED lines from fslist file

		flock --unlock ${_fd} #Release lock on FSTAB
		return 0
	)
	_returnCode=${?} #Return code of sub-process
	exec {_fd}>&-

	return ${_returnCode}
}

#ss__removeSurveyFileEntry()
	#Prints current entries in survey file for removal
	#Return Codes:	0; 1=No Entries
function ss__removeSurveyFileEntry() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	local -a _menuOptions
	local _line
	local _selection

	while (( ${true} )); do
		__printTitle 'Remove Entry'

		while read _line; do
			__printDebugMessage "Processing: ${_line}"
			if [[ ${#_menuOptions[@]} -eq 0 ]]; then #Headers from ss__getSurveyFileEntries
				_menuOptions+=("==${_line}")
			elif [[ "${_line:0:1}" == '#' ]]; then #Remarked entries
				_menuOptions+=("${IRED}${_line}")
			else #Active entries
				_menuOptions+=("${IGREEN}${_line}")
			fi
		done < <(ss__getSurveyFileEntries "all" ${true} ${true} | column -t -s '	' 2>/dev/null)

		__printDebugMessage "Entry Count: ${#_menuOptions[@]}"
		__isColorsLoaded && [[ ${#_menuOptions[@]} -eq 1 ]] && return 1
		! __isColorsLoaded && [[ ${#_menuOptions[@]} -eq 2 ]] && return 1

		_menuOptions+=(
			''
			"P=${IYELLOW}Return to the previous menu"
		)

		__getMenuInput 'Choice:' '_menuOptions' '_selection' || return ${?}
		[[ "${_selection,,}" == 'p' ]] && return 0

		__printTitle 'Remove Entry'
		__printMessage "        ${IWHITE}${UNDR}${_menuOptions[0]:2}"
		__isColorsLoaded || {
			printf -v line '%*s' $(__removeEscapeCodes "${_menuOptions[0]:2}" | wc -m)
			__printMessage "        $(printf '%s\n' "${line// /-}")"
		}
		__printMessage "Remove: $(__removeEscapeCodes "${_menuOptions[${_selection}]}")"
		__printMessage

		read _region _hostname _ip _datacenter _rack _interface < <(__removeEscapeCodes "${_menuOptions[${_selection}]}")
		_menuOptions[${_selection}]="${_region,,},${_hostname,,},${_ip},${_datacenter,,},${_rack,,}$([[ -n "${_interface,,}" ]] && printf ',')${_interface}"

		if __getYesNoInput 'Are you sure you wish to delete this entry?' "${IRED}No"; then
			__printMessage
			__printMessage "${IWHITE}Removing entry in $(ss__getSurveyFileName) ... " ${false}
			__printDebugMessage "Removing: '/^'${_menuOptions[${_selection}]}'$/!p'"
			sed -n -i "/^${_menuOptions[${_selection}]}$/I!p" "$(ss__getSurveyFileName)"
			__printMessage "${IGREEN}Done"
			__printMessage
			__pause
		fi
		_menuOptions=()
	done
}

#ss__resizePartition(DevicePartition)
	#Will resize partition to 100% of disk
	#Return Codes:	0=Success; 1=unmount failure; 2=partition resize failure; 3=filesystem check failure; 4=filesystem resize failure; 5=mount failure
function ss__resizePartition() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local -a _cursorPosition
	local _device="${1:?$(__raiseError 'DevicePartition is required')}"
	local _mountpoint
	local -i _partition _startSector

	_device="${_device//[0-9]}"
	_partition=${1//${_device}}

	if [[ -b "${_device}" && -b "${_device}${_partition}" ]]; then
		_startSector=$(sgdisk --print "${_device}" | tail -n 1 | awk '{print $2}')

		__printMessage "This is going to grow ${IWHITE}${_device}${_partition}."
		__printMessage "  From: ${IWHITE}$(lsblk --noheadings --output SIZE ${_device}${_partition} 2>/dev/null)"
		__printMessage "    To: ${IWHITE}$(lsblk --nodeps --noheadings --output SIZE ${_device} 2>/dev/null)"
		__printMessage
		__getYesNoInput 'Are you sure you want to continue?' 'Yes' || return 0

		_mountpoint="$(lsblk --noheadings --output MOUNTPOINT ${_device}${_partition} 2>/dev/null)"
		if [[ -n "${_mountpoint:-}" ]]; then
			__printMessage "Unmounting ${_device}${_partition} ... " ${false} && _cursorPosition=($(__getCursorPosition)); __printMessage
			if umount ${_device}${_partition}; then
				__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done"
			else
				__printStatusMessage ${_cursorPosition[*]} "${IRED}Failed"
				return 1
			fi
		fi

		__printMessage
		__printMessage 'Resizing partition ... ' ${false} && _cursorPosition=($(__getCursorPosition)); __printMessage
		if sgdisk --delete=${_partition} ${_device} && sgdisk --new=${_partition}:${_startSector} ${_device}; then
			__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done" ${true}
		else
			__printStatusMessage ${_cursorPosition[*]}  "${IRED}Failed"
			__printErrorMessage "Failed to delete or create new partition!"
			__printMessage "The original starting sector was: ${_startSector}"
			return 2
		fi

		__printMessage
		__printMessage 'Running filesystem checks before expanding ... ' ${false} && _cursorPosition=($(__getCursorPosition)); __printMessage
		if e2fsck -f ${_device}${_partition}; then
			__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done" ${true}
		else
			__printStatusMessage ${_cursorPosition[*]} "${IRED}Failed"
			return 3
		fi

		__printMessage
		__printMessage 'Expanding filesystem ... ' ${false} && _cursorPosition=($(__getCursorPosition)); __printMessage
		if resize2fs ${_device}${_partition}; then
			__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done" ${true}
		else
			__printStatusMessage ${_cursorPosition[*]} "${IRED}Failed"
			return 4
		fi

		__printMessage
		__printMessage "Remounting ${_device}${_partition} from ${FSTAB} entry ... " ${false} && _cursorPosition=($(__getCursorPosition)); __printMessage
		if mount ${_device}${_partition}; then
			__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done"
		else
			__printStatusMessage ${_cursorPosition[*]} "${IRED}Failed"
			if [[ -n "${_mountpoint:-}" ]]; then
				__printMessage '  Trying again without ${FSTAB} ... ' ${false} && _cursorPosition=($(__getCursorPosition)); __printMessage
				if mount ${_device}${_partition} "${_mountpoint}"; then
					__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done"
				else
					__printStatusMessage ${_cursorPosition[*]} "${IRED}Failed"
					__printMessage "Please manually remount ${_device}${_partition}."
					return 5
				fi
			else
				__printMessage "Please manually remount ${_device}${_partition}."
				return 5
			fi
		fi
	else
		__printErrorMessage "Unable to located device/partition: ${1}"
	fi

	return 0
}

#ss__runOnCluster(Command, ClusterPassword="", HideCommand=${false})
	#Will execute the supplied command across the non-remarked nodes in the ss_SURVEY_FILE
		#Force error codes 190-199 to indicate a remote command execution error
	#If no ClusterPassword is supplied and no SSH Key file exists, each server will prompt for a password
	#If HideCommand is true, the command string will not be printed
		#Useful for changing passwords
	#Return Codes:	0
function ss__runOnCluster() {
	[[ ${#} -lt 1 || ${#} -gt 3 ]] && __raiseWrongParametersError ${#} 1 3
	local _clusterPassword="${2:-}"
	local _command="${1:?$(__raiseError 'Command is required')}"
	local -a _cursorPosition
	local -i _exitCode
	local -i _hideCommand=${3:-${false}}
	local _server
	local -i _serverPassword=${false}

	(( _hideCommand )) || __printMessage "Executing Command: ${IWHITE}${_command}"
	_command+="; :" #Added to ensure command completes successfully

	ss__installPackage 'sshpass' || :

	__printMessage
	for _server in $(ss__getSurveyFileEntries 'IP' 2>/dev/null); do
		__printMessage "${ICYAN}══> ${RST}On Server: ${IWHITE}${_server}${RST} ... " ${false}; _cursorPosition=($(__getCursorPosition))
		__printMessage "${ICYAN}<══"
		while (( ${true} )); do
			_exitCode=0
			if (( ! _serverPassword )) && [[ -f "$(ss__getSSHKeyFileName)" ]]; then
				__printDebugMessage "Using SSH Key: '$(ss__getSSHKeyFileName)' to '${_server}'"
				if [[ -n "${_clusterPassword}" ]]; then
					__printDebugMessage 'SSH Key + sshpass'
					sshpass -p "${_clusterPassword}" ssh -i "$(ss__getSSHKeyFileName)" -o 'CheckHostIP=no' -o 'StrictHostKeyChecking=no' -o 'VerifyHostKeyDNS=no' -t ${_server} "${_command}" 2>/dev/null || _exitCode=${?}
				else
					ssh -i "$(ss__getSSHKeyFileName)" -o 'CheckHostIP=no' -o 'StrictHostKeyChecking=no' -o 'VerifyHostKeyDNS=no' -t ${_server} "${_command}" 2>/dev/null || _exitCode=${?}
				fi
			elif (( ! _serverPassword )) && [[ -n "${_clusterPassword}" ]]; then
				__printDebugMessage "Using sshpass to '${_server}'"
				sshpass -p "${_clusterPassword}" ssh -o 'CheckHostIP=no' -o 'StrictHostKeyChecking=no' -o 'VerifyHostKeyDNS=no' -t ${_server} "${_command}" 2>/dev/null || _exitCode=${?}
			else
				__printDebugMessage "Manual Password Entry to '${_server}'"
				_serverPassword=${false}
				ssh -o 'CheckHostIP=no' -o 'StrictHostKeyChecking=no' -o 'VerifyHostKeyDNS=no' -t ${_server} "${_command}" 2>/dev/null || _exitCode=${?}
			fi
			case ${_exitCode} in
				0)
					__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done"
					break
					;;
				5) __printStatusMessage ${_cursorPosition[*]} "${IRED}Failed - Permission Denied" ${true} ;;
				127)
					__printStatusMessage ${_cursorPosition[*]} "${IRED}Failed - Command not found" ${true}
					break
					;;
				19[0-9])
					__printStatusMessage ${_cursorPosition[*]} "${IRED}Remote Command Failed (${?})"
					break
					;;
				255) __printStatusMessage ${_cursorPosition[*]} "${IRED}Failed to connect to server" ;;
				*) __printStatusMessage ${_cursorPosition[*]} "${IRED}Unhandled Exit Code: ${_exitCode}" ;;
			esac

			__printMessage
			__getYesNoInput 'Would you like to try a different password?' "${IRED}No" && _serverPassword=${true} || break
		done
		__printMessage
	done

	return 0
}

#ss__saveSetting(VariableName)
	#Saves current variable value to this script
	#Return Codes:	0
function ss__saveSetting() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _variableName="${1:?$(__raiseError 'VariableName is required')}"
	local _variableValue="${!1:?$(__raiseError 'VariableName is undefined')}"

	__printDebugMessage "_variableName=${_variableName}; _variableValue=${_variableValue}"

	if [[ "${_variableValue}" == '0' || "${_variableValue}" == '1' ]]; then
		(( ! ${_variableValue} )) && _variableValue='${false}' || _variableValue='${true}'

		__printDebugMessage "Boolean modified: _variableName=${_variableName}; _variableValue=${_variableValue}" ${true} 2
	fi

	__printDebugMessage "Before sed replacement: $(grep -E "declare( -i)? ${_variableName}" "$(__getDirectoryName)/$(__getFileName)")" ${true} 2
	sed -i "s~\(^declare\( -i\)\? ${_variableName}=['\"]\?\)[^'\"]*\(['\"]\?\)~\1${_variableValue}\3~" "$(__getDirectoryName)/$(__getFileName)"
	__printDebugMessage "After sed replacement: $(grep -E "declare( -i)? ${_variableName}" "$(__getDirectoryName)/$(__getFileName)")" ${true} 2

	return 0
}

#ss__saveSettings()
	#Save all configurable settings to this file
	#Return Codes:	0
function ss__saveSettings() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0

	ss__saveSetting 'INPUT_LIMIT'
	ss__saveSetting 'MAX_SINGLE_COLUMN_OPTIONS'
	ss__saveSetting 'MAX_COLUMN_WIDTH'
	ss__saveSetting 'VLAN_NAME_TYPE'

	ss__saveSetting 'ss_AUTO_UPDATE'
	ss__saveSetting 'ss_SSH_KEY_FILE'
	ss__saveSetting 'ss_STAGING_DIRECTORY'
	ss__saveSetting 'ss_SURVEY_FILE'
	ss__saveSetting 'ss_USE_COLORS'
	ss__saveSetting 'ss_FSTYPE'
	ss__saveSetting 'ss_DISK_MOUNTPATH'

	return 0
}

#ss__setDomainName(DomainName)
	#Sets the system domain name and updates configuration files
	#Return Codes:	0=Successfully updated domain name
function ss__setDomainName() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _currentDomainname="$(__getDomainName || :)"
	local _currentHostname="$(__getHostname || :)"
	local _domainName="${1:?$(__raiseError 'DomainName is required')}"
	local _ipAddress

	ss__createHostsFile
	if [[ -n "${_currentDomainname}" ]] && grep -i -q "${_currentHostname}.${_currentDomainname}" "${HOSTS_FILE}"; then
		__printMessage "Replacing old entries in ${HOSTS_FILE} ... " ${false}
		__modifyFileContents "${HOSTS_FILE}" "${_currentHostname}.${_currentDomainname}" "${_currentHostname,,}.${_domainName,,}" ${false}
	elif [[ "${_currentHostname,,}" != 'localhost' ]]; then
		if grep -i -q "${_currentHostname}" "${HOSTS_FILE}"; then
			__printMessage "Updating existing entry in ${HOSTS_FILE} ... " ${false}
			__modifyFileContents "${HOSTS_FILE}" "${_currentHostname}" "${_currentHostname,,}.${_domainName,,}\t${_currentHostname,,}" ${false}
		else
			__printMessage "Adding entry to ${HOSTS_FILE} ... " ${false}
			_ipAddress="$(hostname -I | awk '{print $1}')"
			if [[ -n "${_ipAddress:-}" ]]; then
				printf '%s\t%s\t%s\n' "${_ipAddress}" "${_currentHostname,,}.${_domainName,,}" "${_currentHostname,,}" >> "${HOSTS_FILE}"
			fi
		fi
	fi
	__printMessage "${IGREEN}Done"

	ss__createSysConfigNetworkFile

	ss__createResolvConfFile
	__printMessage "Modifying ${RESOLV_CONF} ... " ${false}
	__modifyFileContents "${RESOLV_CONF}" '^domain.*' "domain ${_domainName,,}" ${true} #Add/Change domain option
	__modifyFileContents "${RESOLV_CONF}" '^search.*' "search ${_domainName,,}" ${true} #Add/Change search option
	[[ -n "${_currentDomainname}" && "${_currentDomainname,,}" != "${_domainName,,}" ]] && __modifyFileContents "${RESOLV_CONF}" "${_currentDomainname}" "${_domainName,,}" ${false} #Change any other occurrence of previous domain name
	__printMessage "${IGREEN}Done"

	__printMessage 'Updating kernel ... ' ${false}
	sysctl -q -w kernel.domainname="${_domainName,,}"
	__printMessage "${IGREEN}Done"

	if [[ -n "${_currentDomainname}" ]] && grep -i -q -E "kernel.domainname\s*=\s${_currentDomainname}" "${SYSCTL_CONF}"; then
		__printMessage "Replacing old entry in ${SYSCTL_CONF} ... " ${false}
		__modifyFileContents "${SYSCTL_CONF}" "kernel.domainname\s*=\s*${_currentDomainname}" "kernel.domainname = ${_domainName,,}" ${false}
	elif grep -i -q -E 'kernel.domainname\s*=\s*' "${SYSCTL_CONF}"; then
		__printMessage "Updating existing entry in ${SYSCTL_CONF} ... " ${false}
		__modifyFileContents "${SYSCTL_CONF}" 'kernel.domainname\s*=\s*.*$' "kernel.domainname = ${_domainName,,}" ${false}
	else
		__printMessage "Adding entry to ${SYSCTL_CONF} ... " ${false}
		printf 'kernel.domainname = %s\n' "${_domainName,,}" >> ${SYSCTL_CONF}
	fi
	__printMessage "${IGREEN}Done"

	return 0
}

#ss__setHostname(Hostname)
	#Sets the system hostname and updates configuration files
	#Return Codes:	0=Successfully Updated
function ss__setHostname() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _currentDomainname="$(__getDomainName || :)"
	local _currentHostname="$(__getHostname || :)"
	local _hostname="${1:?$(__raiseError 'Hostname is required')}"
	local _ipAddress

	ss__createHostsFile
	if [[ "${_hostname,,}" != 'localhost' && "${_hostname,,}" != 'localhost.localdomain' ]]; then
		if [[ -n "${_currentHostname:-}" ]] && [[ "${_currentHostname,,}" != 'localhost' && "${_currentHostname,,}" != 'localhost.localdomain' ]] && grep -i -q "${_currentHostname}" "${HOSTS_FILE}"; then
			__printMessage "Replacing old entries in ${HOSTS_FILE} ... " ${false}
			sed -i "s~${_currentHostname}~${_hostname,,}~gI" "${HOSTS_FILE}"
		else
			__printMessage "Adding entry to ${HOSTS_FILE} ... " ${false}
			_ipAddress="$(hostname -I | awk '{print $1}')"
			if [[ -n "${_ipAddress:-}" ]]; then
				if [[ -n "${_currentDomainname:-}" ]]; then
					printf '%s\t%s\t%s\n' "${_ipAddress}" "${_hostname,,}.${_currentDomainname,,}" "${_hostname,,}" >> "${HOSTS_FILE}"
				else
					printf '%s\t%s\n' "${_ipAddress}" "${_hostname,,}" >> "${HOSTS_FILE}"
				fi
			fi
		fi
		__printMessage "${IGREEN}Done"
	fi

	ss__createSysConfigNetworkFile
	if grep -E -q '^HOSTNAME=.*$' "${SYSCONFIG_NETWORK}"; then
		__printMessage "Modifying HOSTNAME setting in ${SYSCONFIG_NETWORK} ... " ${false}
		sed -i "s~^HOSTNAME=.*$~HOSTNAME=\"${_hostname,,}\"~i" "${SYSCONFIG_NETWORK}"
	else
		__printMessage "Adding HOSTNAME setting to ${SYSCONFIG_NETWORK} ... " ${false}
		printf 'HOSTNAME="%s"\n' "${_hostname,,}" >> "${SYSCONFIG_NETWORK}"
	fi
	__printMessage "${IGREEN}Done"

	__printMessage 'Updating kernel ... ' ${false}
	sysctl -q -w kernel.hostname="${_hostname,,}"
	__printMessage "${IGREEN}Done"

	return 0
}

#ss__setTimezone(ZoneFile)
	#Sets timezone to ZoneFile
	#Return Codes:	0=Success; 1=Cancelled
	#Exit Codes:	1
function ss__setTimezone() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _ntpServer='pool.ntp.org'
	local _zoneFile="${1:?$(__raiseError 'ZoneFile is required')}"

	if [[ -f "${TZ_DIR}/${_zoneFile}" ]]; then
		__printTitle 'Set Timezone' "Timezone: ${_zoneFile}"
		__printMessage "Local Time:  ${IWHITE}$(LANG='C' TZ="${TZ_DIR}/${_zoneFile}" date)"
		__printMessage "  UTC Time:  ${IWHITE}$(LANG='C' TZ='UTC0' date)"
		__printMessage
		__getYesNoInput 'Would you like to save this timezone setting?' 'Yes' || return 1
		__printMessage 'Saving timezone settings ... ' ${false}
		ln -sf "${TZ_DIR}/${_zoneFile}" "${TZ_LOCALTIME}"
		printf "ZONE=\"${_zoneFile}\"" > "${CLOCKFILE}"
		__printMessage "${IGREEN}Done"
		__printMessage

		if false && __getYesNoInput 'Would you like to sync the clock to an NTP server now?' 'Yes'; then
			if __installPackage 'ntp ntpdate'; then
				if __getInput 'NTP Server:' '_ntpServer' "${_ntpServer}" ${false} '.+'; then
					if /etc/init.d/ntpd status >/dev/null 2>&1; then
						__printMessage 'Stopping ntpd service ... ' ${false}
						/etc/init.d/ntpd stop >/dev/null 2>&1 && __printMessage "${IGREEN}Done" || __printMessage "${IRED}Failed"
					fi
					__printMessage "Attempting to sync to ${_ntpServer} now ... " ${false}
					ntpdate -s "${_ntpServer}" && __printMessage "${IGREEN}Done" || __printMessage "${IRED}Failed"

					__printMessage 'Starting ntpd service ... ' ${false}
					/etc/init.d/ntpd start >/dev/null 2>&1 && __printMessage "${IGREEN}Done" || __printMessage "${IRED}Failed"
				fi
			fi
		fi
		hwclock --systohc
		__pause
	else
		__printErrorMessage "Invalid timezone '${_zoneFile}'" ${true} 1
	fi

	return 0
}

#ss__trapExit()
	#Ensures prompt is put back to normal and prints a thank you message
	#Return Codes:	<none>
	#Exit Codes:	<none>
function ss__trapExit() {
	__trapExit
	(( ss_REBOOT )) && __printMessage "${IRED}Please reboot for changes to take effect!"
	__printMessage "${IWHITE}Thank you for using the Cloudian System Configuration script."
}

#ss__updateSystem()
	#Performs a upgrade of all packages on system silently
	#Will set ${ss_REBOOT}=${true} if the kernel is upgraded
	#Return Codes:	0=Success; 1=Upgrade Failed
	#Exit Codes:	
function ss__updateSystem() {
	#Dependencies:	__printMessage
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0
	local _date="$(date -u +%FT%T)"

	__printMessage 'Performing system upgrade ... ' ${false}
	if yum -y --nogpgcheck upgrade > "$(__getDirectoryName)/yum-upgrade-${_date}.log" 2>&1; then
		__printMessage "${IGREEN}Done"
	else
		__printMessage "${IRED}Failed"
		__printMessage "Please check $(__getDirectoryName)/yum-upgrade-${_date}.log for errors"
		return 1
	fi

	if grep -q -i 'kernel-firmware' "$(__getDirectoryName)/yum-upgrade-${_date}.log"; then
		__printMessage 'The kernel has been upgraded, you should reboot.'
		ss_REBOOT=${true}
	fi

	return 0
}
### ########################## ###


### Menus ###
### ############## ###

#ss__menu_disks()
    #Configure disks for HyperStore usage
	#Return Codes:	0
	#Exit Codes:
function ss__menu_disks() {
	local -a _menuOptions _selectedDisks
	local _selection
	local -i _i

	#private__toggleSelection(MenuEntryIndex, IgnoreDependencies=${false})
		#Toggles the selection state for the provided MenuEntryIndex within _menuOptions array
		#If IgnoreDependencies=${true}, will not prompt if you are sure to disks with Dependencies (partitions and mount points)
	function private__toggleSelection() {
		local -i _entry=${1:?$(__raiseError 'MenuEntryIndex is required')}
		local -i _ignoreDependencies=${2:-${false}}
		local _selection
		
		[[ ${#_selectedDisks[@]} -gt 0 ]] && _selection=" ${_selectedDisks[*]} "

		_dependencies=$(__removeEscapeCodes "${_menuOptions[${_entry}]}" | awk '{print $3}')
		_disk="$(__removeEscapeCodes "${_menuOptions[${_entry}]}" | awk '{print $1}')"
		if [[ ${#_selectedDisks[@]} -gt 0 && "${_selection// ${_disk} }" != "${_selection}" ]]; then
			_selectedDisks=(${_selection// ${_disk} / })
			if [[ ${_dependencies} -gt 0 ]]; then
				_menuOptions[${_entry}]="${IRED}$(__removeEscapeCodes "${_menuOptions[${_entry}]}")"
			else
				_menuOptions[${_entry}]="$(__removeEscapeCodes "${_menuOptions[${_entry}]}")"
			fi
			if [[ ${#_selectedDisks[@]} -eq 0 ]]; then
				_menuOptions[$((${#_menuOptions[@]} - 7))]="--C=${IGREEN}Configure selected disks"
				_menuOptions[$((${#_menuOptions[@]} - 8))]='--'
			fi

			return 0
		elif (( ! ${_ignoreDependencies} )) && [[ ${_dependencies} -gt 0 ]]; then
			__printMessage
			__printMessage "${IRED}WARNING: /dev/${_disk} is already configured!"
			__printMessage
			lsblk --output NAME,TYPE,SIZE,MOUNTPOINT "/dev/${_disk}"
			__printMessage
			__printMessage "${IYELLOW}Configure this disk will erase everything on it."
			__getYesNoInput 'Are you sure you want to configure this disk' "${IRED}No" || return 0
		fi

		_selectedDisks+=(${_disk})
		_selectedDisks=($(IFS=$'\n'; sort -u <<<"${_selectedDisks[*]}"; unset IFS))
		_menuOptions[${_entry}]="${IGREEN}$(__removeEscapeCodes "${_menuOptions[${_entry}]}")"
		_menuOptions[$((${#_menuOptions[@]} - 7))]="C=${IGREEN}Configure selected disks"
		_menuOptions[$((${#_menuOptions[@]} - 8))]=''

		return 0
	}

	function private__loadDiskDetails() {
		local -a _cursorPosition
		local _disk _line
		local -i _lineCount=0 _dependencies

		__rescanDisks
		_menuOptions=()
		_selectedDisks=()

		__printMessage "${IWHITE}Loading disk information ... " ${false}; _cursorPosition=($(__getCursorPosition)); __printMessage
		while read _line; do
			__printDebugMessage "Processing: ${_line}"
			if [[ ${_lineCount} -eq 0 ]]; then
				_menuOptions+=("==${_line}") #Headers
			else
				_dependencies=$(printf "${_line}" | awk '{print $3}')
				_disk="$(printf "${_line}" | awk '{print $1}')"
				if [[ ${_dependencies} -gt 0 ]]; then
					_menuOptions+=("${IRED}${_line}")
				else
					_menuOptions+=("${IGREEN}${_line}")
					_selectedDisks+=("${_disk}")
				fi
			fi
			(( ++_lineCount ))
		done < <(ss__getDisks ${true} 2>/dev/null | column -t -s '	')
		__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done"
		__printDebugMessage "Loaded ${_lineCount} Disk Entries"

		[[ ${#_menuOptions[@]} -eq 1 ]] && _menuOptions[0]='**No Disks Detected'

		_menuOptions+=(
			"$([[ ${#_selectedDisks[@]} -gt 0 ]] || printf '%s' '--')"
			"$([[ ${#_selectedDisks[@]} -gt 0 ]] || printf '%s' '--')C=${IGREEN}Configure Selected Disks"
			"$([[ ${#_menuOptions[@]} -gt 1 ]] || printf '%s' '--')"
			"$([[ ${#_menuOptions[@]} -gt 1 ]] || printf '%s' '--')T=Toggle Selection for all disks"
			''
			'R=Refresh Disks'
			''
			"P=${IYELLOW}Return to the previous menu"
		)
	}

	private__loadDiskDetails

	while (( ${true} )); do
		__printTitle 'Setup Disks' "Selected Disks: $([[ ${#_selectedDisks[@]} -gt 0 ]] && printf "${_selectedDisks[*]}" || printf '<none>')"
		__getMenuInput 'Toggle devices by selecting the number listed beside device\n\nChoice:' '_menuOptions' '_selection' || break
		case "${_selection,,}" in
			'c') #Configure disks
				if ! ss__installPackage 'gdisk'; then
					__printErrorMessage 'gdisk is required to configure disks'
					__pause
					return
				fi

				ss__configureDisks "${_selectedDisks[*]}"
				__pause
				private__loadDiskDetails
				;;
			'p') break ;; #Previous menu
			'r') private__loadDiskDetails ;; #Refresh disks
			't') #Toggle selection for each disk
				__printTitle 'Setup Disks'
				if __getYesNoInput "${IRED}This can select disks that might already be configured.${RST}\nAre you sure you want to continue?" "${IRED}no"; then
					for (( _i=1; _i < ${#_menuOptions[@]}; _i++)); do
						[[ ${_menuOptions[${_i}]:1:1} != '=' && ${_menuOptions[${_i}]} != '' ]] && private__toggleSelection ${_i} ${true}
					done
				fi
				;;
			*) private__toggleSelection ${_selection} ;; #Toggle selected disk
		esac
	done

	return 0
}

#ss__menu_main()
	#Main Menu when running in interactive mode
function ss__menu_main() {
	local _clusterPassword
	local _hyperstoreFile
	local -a _menuOptions
	local _selection

	(( ss_USE_COLORS )) && __loadColors || __unloadColors
	[[ ${#} -ge 1 ]] && ss__parseArguments "${@}" #Parse command line arguments

	trap __trapCtrlC SIGINT
	trap __trapCtrlZ SIGTSTP
	trap ss__trapExit EXIT
	trap __onError ERR

	if (( ss_UPDATED )); then
		ss_UPDATED=${false}
		ss__saveSetting 'ss_UPDATED'
		__printMessage 'Welcome back after updating to the latest version!'
	elif (( ss_AUTO_UPDATE )); then
		__clearScreen
		ss__onlineUpdate || __printMessage
	else
		__clearScreen
	fi

	if (( ss_REMOTE )); then
		ss__configureHyperStorePrerequisites ${true}
		__printMessage "${IYELLOW}Finished HyperStore Prerequisites"
		__printMessage "${IWHITE}Pausing 5 seconds, press Ctrl+C to exit now"
		sleep 5
		ss__menu_disks <<-EOF
			C
			P
		EOF
		__printMessage "${IYELLOW}Finished Configuring HyperStore Disks"
		__printMessage "${IWHITE}Pausing 5 seconds, press Ctrl+C to exit now"
		sleep 5
		ss__getTimezone
	fi

	while (( ${true} )); do
		_menuOptions=(
			'Configure Networking' #0
			'Change timezone' #1
			'Setup Disks' #2
			'Setup Survey.csv File' #3
			"**${IRED}Survey File '$(ss__getSurveyFileName)' Not Found" #4
			"Change ${USER} Password" #5
			"**${IRED}Please Change Password" #6
			'Install & Configure Prerequisites' #7
			'Run commands on each cluster node' #8
			'Copy local file to each cluster node' #9
			'' #10
			'R=Run pre-installation checks' #11
			'' #12
			'D=Download HyperStore Files' #13
			"**${IRED}Please Download or place the HyperStore files in '${ss_STAGING_DIRECTORY}'" #14
			'' #15
			'S=Script Settings' #16
			"**${IRED}Staging Directory '${ss_STAGING_DIRECTORY}' Not Found" #ss__hyperstoreSysPrepDownloader17
			"A=About $(__getFileName)" #18
			'' #19
			"X=${IRED}Exit" #20
		)

		if [[ ! -f "$(__getDirectoryName)/preInstallCheck.sh" && ! -f "${ss_STAGING_DIRECTORY}/preInstallCheck.sh"  && ! -f "$(which preInstallCheck.sh 2>/dev/null)" ]]; then #hide pre-installation checks options when script isn't found
			_menuOptions[10]="--${_menuOptions[10]}"
			_menuOptions[11]="--${_menuOptions[11]}"
		fi

		if ! __checkInstalledPackage 'gdisk'; then #if gdisk isn't installed, hide disk menu option
			_menuOptions[2]="--${_menuOptions[2]}"
		fi

		[[ -d "${ss_STAGING_DIRECTORY}" ]] && _menuOptions[17]="--${_menuOptions[17]}" #hide staging directory warning when directory exists

		if [[ -f "$(ss__getSurveyFileName)" ]]; then #hide survey file warning when file exists
			if ! grep -q -E "${ss_SURVEY_ENABLED_REGEX}" "$(ss__getSurveyFileName)" 2>/dev/null; then #Change message when no entries exist
				_menuOptions[4]="**${IRED}Survey file '$(ss__getSurveyFileName)' has no enabled entries."
			else
				_menuOptions[4]="--${_menuOptions[4]}"
			fi
		elif [[ ! -d "${ss_STAGING_DIRECTORY}" && "$(ss__getSurveyFileName)" =~ ${ss_STAGING_DIRECTORY} ]]; then #hide survey file warning when it should be in the staging directory and the directory doesn't exist
			_menuOptions[4]="--${_menuOptions[4]}"
		fi

		if ! grep -q -E "${ss_SURVEY_ENABLED_REGEX}" "$(ss__getSurveyFileName)" 2>/dev/null; then #hide entries that require a survey file
			_menuOptions[8]="--${_menuOptions[8]}"
			_menuOptions[9]="--${_menuOptions[9]}"
			_menuOptions[10]="--${_menuOptions[10]}"
			_menuOptions[11]="--${_menuOptions[11]}"
		fi

		_hyperstoreFile="$(ss__printNewestHyperStoreBinaryVersion || :)"
		if [[ ! -f "${_hyperstoreFile:-}" ]]; then #hide entries that need the binary file
			_menuOptions[3]="--${_menuOptions[3]}"
			_menuOptions[4]="--${_menuOptions[4]}"
			_menuOptions[7]="--${_menuOptions[7]}"
			_menuOptions[8]="--${_menuOptions[8]}"
			_menuOptions[9]="--${_menuOptions[9]}"
			_menuOptions[10]="--${_menuOptions[10]}"
			_menuOptions[11]="--${_menuOptions[11]}"
		else
			_menuOptions[12]="--${_menuOptions[12]}"
			_menuOptions[13]="--${_menuOptions[13]}"
			_menuOptions[14]="--${_menuOptions[14]}"
		fi

		ss__isCurrentPasswordSimple || _menuOptions[6]="--${_menuOptions[6]}"

		__printTitle "${BREADCRUMBS[0]}"
		if __getMenuInput 'Choice:' '_menuOptions' '_selection'; then
			case "${_selection}" in
				'1') #Configure Networking
					__addBreadcrumb 'Networking'
					ss__menu_networking
					__removeBreadcrumb 'Networking'
					;;
				'2') ss__getTimezone ;; #Change Timezone
				'3') ss__menu_disks ;; #Configure Disks
				'4') ss__menu_surveyFile ;; #Setup Survey File
				'5') #Change Password
					__printTitle "Change ${USER} Password"
					if ss__changePassword; then
						__printMessage "${IGREEN}${USER} password successfully changed"
					else
						__printMessage "${IYELLOW}Password has not been changed"
					fi
					__printMessage
					__pause
					;;
				'6') #Configure HyperStore Prerequisites
					__printTitle 'Install & Configure Prerequisites'
					__printMessage
					if grep -q -E "${ss_SURVEY_ENABLED_REGEX}" "$(ss__getSurveyFileName)" 2>/dev/null && __getYesNoInput 'Would you like to perform this on all nodes listed in your survey file?' 'Yes'; then
						__printMessage
						if [[ -f "$(ss__getSSHKeyFileName)" ]]; then
							__printMessage "Using SSH Key: $(ss__getSSHKeyFileName)"
							__printMessage 'If you are prompted for your password, try "Push SSH Key File to cluster nodes" in Script Settings'
						else
							__logMessage 'No SSH Key File'
							__printMessage "If your ${USER} password is the same on all (or most) nodes in the cluster, you can supply it as a cluster password"
							__printMessage 'If you do not want to supply a password, each server will prompt for one when connecting.'
							__printMessage
							__getInput 'Cluster Password:' '_clusterPassword' '' ${true} || break
							[[ -n "${_clusterPassword:-}" ]] && ss__installSSHKeyFile "$(ss__getSSHKeyFileName)" "${_clusterPassword:-}"
						fi
						__printMessage

						#Extract and copy selfextract_prereq.bin to other nodes if available
						[[ ! -f "${ss_STAGING_DIRECTORY}/selfextract_prereq.bin" ]] && ss__extractHyperStoreBinaryPackagedFile 'selfextract_prereq.bin' || :
						[[ -f "${ss_STAGING_DIRECTORY}/selfextract_prereq.bin" ]] && __printMessage "${IWHITE}Copying Packages to cluster nodes" && ss__copyFileToCluster "${ss_STAGING_DIRECTORY}/selfextract_prereq.bin" "${_clusterPassword:-}"

						__printMessage "${IWHITE}Copying System Setup script to cluster nodes"
						ss__copyFileToCluster "$(__getDirectoryName)/$(__getFileName)" "${_clusterPassword:-}"

						if ! ss__runOnCluster "$(__getDirectoryName)/$(__getFileName) --remote --prerequisites $(__isDebugEnabled && printf '%s' ' --debug')" "${_clusterPassword:-}" ${true}; then
							__printMessage
							__printErrorMessage 'Failed to configure HyperStore Prerequisites'
						fi
					else
						__printMessage
						if ! ss__configureHyperStorePrerequisites; then
							__printMessage
							__printErrorMessage 'Failed to configure HyperStore Prerequisites'
						fi
						__printMessage
						__pause
					fi
					;;
				'7') #Run command across cluster
					__printTitle 'Run On Cluster'
					if [[ -f "$(ss__getSSHKeyFileName)" ]]; then
						__printMessage "Using SSH Key: $(ss__getSSHKeyFileName)"
						__printMessage 'If you are prompted for your password, try "Push SSH Key File to cluster nodes" in Script Settings'
					else
						__logMessage 'No SSH Key File'
						__printMessage "If your ${USER} password is the same on all (or most) nodes in the cluster, you can supply it as a cluster password"
						__printMessage 'If you do not want to supply a password, each server will prompt for one when connecting.'
						__printMessage
						__getInput 'Cluster Password:' '_clusterPassword' '' ${true} || break
						[[ -n "${_clusterPassword:-}" ]] && ss__installSSHKeyFile "$(ss__getSSHKeyFileName)" "${_clusterPassword:-}"
					fi
					__printMessage

					while (( ${true} )); do
						__printTitle 'Run On Cluster'
						if __getInput 'Enter command to run:' '_selection' '' ${false} '.+'; then
							if __getYesNoInput 'Did you type your command correctly?' 'Yes'; then
								__printMessage
								ss__runOnCluster "${_selection}" "${_clusterPassword:-}"
								__getYesNoInput 'Would you like to run another command?' 'Yes' || break
							fi
						else
							__getYesNoInput 'Would you like to try again?' "${IRED}No" || break
						fi
						__printMessage
					done
					unset _clusterPassword
					;;
				'8') #Copy file to cluster nodes
					while :; do
						__printTitle 'Copy To Cluster'
						if [[ -f "$(ss__getSSHKeyFileName)" ]]; then
							__logMessage "Using SSH Key: $(ss__getSSHKeyFileName)"
							__printMessage 'If you are prompted for your password, try "Push SSH Key File to cluster nodes" in Script Settings'
						else
							__logMessage 'No SSH Key File'
							__printMessage "If your ${USER} password is the same on all (or most) nodes in the cluster, you can supply it as a cluster password"
							__printMessage 'If you do not want to supply a password, each server will prompt for one when connecting.'
							__printMessage
							__getInput 'Cluster Password:' '_clusterPassword' '' ${true} || break
							[[ -n "${_clusterPassword:-}" ]] && ss__installSSHKeyFile "$(ss__getSSHKeyFileName)" "${_clusterPassword:-}"
						fi
						__printMessage
						if __getInput 'Local file to copy:' '_selection' '' ${false} '.+' && __printMessage && ss__copyFileToCluster "${_selection}" "${_clusterPassword:-}"; then
							__getYesNoInput 'Would you like to copy another file?' "${IRED}No" || break
						else
							__getYesNoInput 'Would you like to try again?' "${IRED}No" || break
						fi
					done

					unset _clusterPassword
					;;
				'A') #About Information
					__clearScreen
					__printMessage "${IGREEN}$(ss__printASCIILogo)"
					__printMessage
					ss__printCopyright
					fold -sw $(tput cols) <<-EOF

						This script is for configuring a CentOS or RHEL system for the Cloudian HyperStore object storage solution.

						Find more information about Cloudian and HyperStore at: ${IWHITE}http://www.cloudian.com/${RST}

						The latest version of this script can found at: ${IWHITE}${ss_uri%\\dl*}${RST}

					EOF
					__pause
					;;
				'D') #Download Cloudian HyperStore Binary File (GA)
					__printTitle 'HyperStore Downloader'
					__printMessage
					if __downloadURI "${ss_versionsURL}" "$(__getDirectoryName)/versions.txt" 'HyperStore Version Information'; then
						__printMessage
						ss__hyperstoreSysPrepDownloader "$(__getDirectoryName)/versions.txt" "HyperStore-FTP"
						ss__hyperstoreSysPrepDownloader "$(__getDirectoryName)/versions.txt" "License"
						__removeFile "$(__getDirectoryName)/versions.txt" >/dev/null
					else
						__printErrorMessage 'Unable to automatically download Cloudian HyperStore files'
					fi
					__printMessage
					__pause
					;;
				'R') ss__menu_preInstallCheck ;; #Pre-Installation Checks
				'S') ss__menu_settings ;; #Settings
				'X') break ;; #Exit
			esac
		else
			break
		fi
	done

	return 0
}

#ss__menu_networking()
	#Configure hostname, domain name, network interfaces, bonding and VLANs
	#Return Codes:	0
function ss__menu_networking() {
	local IFS
	local _input _interface _interfaceMaster _interfaceMode _interfaceType
	local -a _menuOptions
	local _selection

	while (( ${true} )); do
		__printTitle 'Networking'
		IFS=$'\n'; _menuOptions=($(__printNetworkInterfaceDetails ${true} | column -t -s $'\t')); unset IFS
		[[ ${#_menuOptions[*]} -eq 1 ]] && _menuOptions[0]='**No network interfaces found'
		_menuOptions[0]="==${_menuOptions[0]}"
		for _selection in "${!_menuOptions[@]}"; do
			[[ "${_menuOptions[${_selection}]}" =~ ^\ +[^\ ]+$ ]] && _menuOptions[${_selection}]="++${_menuOptions[${_selection}]}"
		done
		_menuOptions+=(
			''
			"**Select a number from the list above to edit an interface's configuration"
			''
			"D=Change Domain Name ($(__getDomainName || printf '<unset>'))"
			"H=Change Hostname ($(__getHostname || printf '<unset>'))"
			''
			'B=Create Bond Interface'
			'V=Create VLAN Interface'
			''
			'N=Restart Networking'
			'R=Refresh Interface Details'
			"$((( ss_RESTART_NETWORKING )) || printf '%s' '--')**${IRED}Network settings have change!${RST}"
			"$((( ss_RESTART_NETWORKING )) || printf '%s' '--')**Please restart networking for them to take effect"
			''
			"P=${IYELLOW}Return to the previous menu"
		)
		if [[ "${_menuOptions[0]}" == '==**No network interfaces found' ]]; then
			_menuOptions[1]="--${_menuOptions[1]}"
			_menuOptions[2]="--${_menuOptions[2]}"
		fi
		__getMenuInput 'Choice:' '_menuOptions' '_selection' '' ${INPUT_RETURN_STYLE_SELECTED_VALUE} || break
		case "${_selection%%=*}" in
			'B') #Create Bond Interface
				if __loadKernelModule 'bonding'; then
					__printDebugMessage 'Bonding module loaded successfully'
				else
					__printErrorMessage 'Failed to load bonding module. Bond interfaces may not work.'
					pause
				fi

				while :; do
					__printMessage
					__getInput 'Bond Interface Name:' '_input' 'bond0' ${false} '^[a-z][a-z0-9]*[0-9]+$' || {
						__pause
						break
					}
					if [[ "$(cat /sys/class/net/bonding_masters)" =~ "${_input}" ]]; then
						__printMessage
						__printMessage 'Bond Interface Already Exists'
						__printMessage
						__getYesNoInput 'Would you like to try a different name?' 'Yes' && continue || break
					fi
					__addBreadcrumb 'Create New Bond'
					if ss__createNetworkConfig "${_input}" 'bond'; then
						echo "+${_input}" > /sys/class/net/bonding_masters 2>/dev/null || :
						__printMessage "Bond interface ${IWHITE}${_input}${RST} has been created."
						__printMessage
						if __getYesNoInput 'Would you like to add slave interfaces now?' 'Yes'; then
							ss__menu_networking_bonding_addslave "${_input}"
							__printTitle 'Create New Bond' "Bond Interface: ${_input}"
							__restartNetworkInterface "${_input}"
						fi
					else
						__printMessage
						__printMessage "${IRED}Bond Interface ${IWHITE}${_input}${IRED} was not created."
					fi
					__removeBreadcrumb 'Create New Bond'
					__printMessage
					__pause
					break
				done
				;;
			'D') #Domain name
				__printTitle 'Domain Name' "Current Domain Name: $(__getDomainName || printf '%s' '<unset>')"
				if __getYesNoInput 'Do you want to change your domain name?' "${IRED}No"; then
					__getInput 'New Domain Name:' '_input' "$(__getDomainName || :)" ${false} '.+' || continue
					ss__setDomainName "${_input}"
					__pause
				fi
				;;
			'H') #Hostname
				__printTitle 'Hostname' "Current Hostname: $(__getHostname || printf '<unset>')"
				if __getYesNoInput 'Do you want to change your hostname?' "${IRED}No"; then
					__getInput 'New Hostname:' '_input' "$(__getHostname || :)" ${false} "${ss_hostnameRegEx}" || continue
					ss__setHostname "${_input}"
					__pause
				fi
				;;
			'P') break;; #Return to the previous menu
			'N') #Restart Networking
				__printMessage "${IRED}You could be disconnected if using a remote session"
				__getYesNoInput 'Are you sure?' 'yes' || continue
				[[ ! -f "${SYSCONFIG_NETWORK}" ]] && touch "${SYSCONFIG_NETWORK}"
				service network restart || :
				ss_RESTART_NETWORKING=${false}
				__pause
				;;
			'R') continue ;;
			'V') ss__menu_networking_vlan;; #Create VLAN Interface
			*) #Should be a network interface
				__printDebugMessage "_selection='${_selection}'"
				_interface="$(__removeEscapeCodes "${_selection}" | awk '{print $1}')"
				_interfaceType="$(__removeEscapeCodes "${_selection}" | awk '{print $4}')"
				_interfaceMode="$(__removeEscapeCodes "${_selection}" | awk '{print $5}')"
				_interfaceMaster="$(__removeEscapeCodes "${_selection}" | awk '{print $6}')"
				__printMessage
				case "${_interfaceType,,}" in
					'bond')
						if [[ "${_interfaceMode,,}" == 'slave' ]]; then
							__printMessage "${_interface} is currently a slave interface for bond ${_interfaceMaster}."
							if __getYesNoInput 'Do you want to remove this slave and reconfigure the interface?' "${IRED}No"; then
								__stopNetworkInterface "${_interface}" || :
								echo "-${_interface}" > /sys/class/net/${_interfaceMaster}/bonding/slaves 2>/dev/null || :
								ss__createNetworkConfig "${_interface}" 'Ethernet' && __startNetworkInterface "${_interface}" || :
							fi
						else
							ss__menu_networking_bonding "${_interface}"
						fi
						;;
					*)
						while ss__menu_networking_existing "${_interface}"; do
							[[ "${_interfaceType,,}" == 'vlan' ]] && _interface="${_interfaceMode}"
							if ss__createNetworkConfig "${_interface}" "${_interfaceType,,}" "${_interfaceMaster:-}"; then
								__printMessage
								__printMessage "${IRED}You could be disconnected by restarting this interface."
								__printMessage
								if __getYesNoInput 'Would you like to restart this interface to activate this new configuration?' 'Yes'; then
									__restartNetworkInterface "${_interface}"
									__pause
								fi
							else
								case ${?} in
									1)
										__printMessage
										__printMessage "${IRED}Configuration was not saved."
										__printMessage
										__getYesNoInput 'Would you like to try again?' "${IRED}No" || break
										;;
									2|99) break;;
								esac
							fi
						done
						;;
				esac
				;;
		esac
	done

	return 0
}

#ss__menu_networking_existing(Interface)
	#Handles existing network configurations for Interface
	#Return Codes:	0=No/Overwrite Configuration; 1=Existing Configuration
function ss__menu_networking_existing() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local -a _existingOptions
	local IFS=$'\n'
	local _interface="${1:?$(__raiseError 'Interface is required')}"
	local _interfaceConfigFile="${SYSCONFIG_NETWORK_SCRIPTS}/ifcfg-${_interface}"

	while (( ${true} )); do
		IFS=$'\n'; _existingOptions=($(__printNetworkInterfaceDetails ${true} | awk -v _interface="${_interface,,}" '{ if(NR == 1 || tolower($1) == _interface) { print $0 }; };' | column -t -s $'\t')); unset IFS
		_existingOptions[0]="**${IWHITE}${UNDR}${_existingOptions[0]}${RST}"
		_existingOptions[1]="**${_existingOptions[1]}"
		_existingOptions+=(
			''
			"$([[ -f "${_interfaceConfigFile}" ]] || printf '%s' '--')Show Configuration"
			'Edit Configuration'
			"$([[ "$(__printInterfaceConfigValue "${_interface}" 'ONBOOT')" =~ 'yes' ]] && printf 'Disable' || printf 'Enable')"
			''
			'R=Restart'
			''
			"D=${IRED}Delete Configuration"
			''
			"P=${IYELLOW}Return to the previous menu"
		)
		__printTitle 'Interface Configuration' "${IWHITE}Hostname:${RST} $(__getHostname || printf '<unset>')"
		if [[ -f "${_interfaceConfigFile}" ]]; then
			__getMenuInput 'Choice:' '_existingOptions' '_input' || return ${?}
			__printMessage
			case "${_input}" in
				'P') break;; #Return to the previous menu
				'D') #Delete Configuration
					__printTitle 'Delete Interface Configuration' "Interface: ${IWHITE}${_interface}"
					if [[ $(__printNetworkInterfaceDetails ${true} | awk -v _interface="${_interface,,}" '{ if(tolower($6) == _interface) { print $0 }; };' | wc -l) -gt 0 ]]; then
						__printMessage "${IRED}This action could impact the following interface(s) as well:"
						__printMessage
						__printNetworkInterfaceDetails ${true} | awk -v _interface="${_interface,,}" '{ if(NR == 1 || tolower($6) == _interface) { print $0 }; };' | column -t -s $'\t'
						__printMessage
					fi
					if __getYesNoInput "Are you sure you want to delete ${IWHITE}${_interface}${RST}?" "${IRED}No"; then
						__printMessage
						if __getYesNoInput 'Would you like to shutdown this interface now?' "${IRED}No"; then
							__printMessage
							__stopNetworkInterface "${_interface}"
						else
							__printMessage
							__printMessage 'You will need to restart networking for this change to take place'
							ss_RESTART_NETWORKING=${true}
						fi
						__printMessage
						__removeFile "${_interfaceConfigFile}"
						__printMessage
						__pause
						break
					fi
					;;
				1) #Display Configuration
					__printTitle 'Interface Configuration' "Interface: ${IWHITE}${_interface}"
					__printMessage "${IWHITE}${_interfaceConfigFile}:"
					cat "${_interfaceConfigFile}"
					__printMessage
					__pause
					;;
				2) return 0;; #Edit Configuration
				3) #Enable/Disable Configuration
					if [[ "$(__printInterfaceConfigValue "${_interface}" 'ONBOOT')" =~ 'yes' ]]; then #Currently Enabled
						if __getYesNoInput 'Would you like to shutdown this interface now?' "${IRED}No"; then
							__printMessage
							sed -i -r 's~^ONBOOT=.*$~ONBOOT="no"~i' "${_interfaceConfigFile}"
							__stopNetworkInterface "${_interface}"
							__printMessage
							__pause
						fi
					else #Currently Disabled
						if __getYesNoInput 'Would you like to start this interface now?' 'Yes'; then
							__printMessage
							sed -i -r 's~^ONBOOT=.*$~ONBOOT="yes"~i' "${_interfaceConfigFile}"
							__startNetworkInterface "${_interface}"
							__printMessage
							__pause
						fi
					fi
					;;
				'R') #Restart Interface
					__printMessage "${IRED}You could be disconnected by restarting this interface."
					if __getYesNoInput 'Are you sure?' "${IRED}No"; then
						__printMessage
						__restartNetworkInterface "${_interface}"
						__pause
					fi
					;;
			esac
		else
			return 0
		fi
	done

	return 1
}

#ss__menu_networking_vlan()
	#Gathers information to build a new vlan interface
function ss__menu_networking_vlan() {
	[[ ${#} -ne 0 ]] && __raiseWrongParametersError ${#} 0
	local _interfaceMaster
	local -a _interfaces
	local -i _vlan
	local _vlanInterfaceName

	if ! lsmod | grep -i -q '8021q'; then
		if modprobe --first-time 8021q 2>/dev/null; then
			__printDebugMessage '802.1q module loaded successfully'
		else
			__printErrorMessage 'Failed to load 802.1q module. VLAN interfaces may not work.'
			__pause
		fi 
	fi

	while (( ${true} )); do
		__printTitle 'Create New VLAN'
		_interfaces=(
			$(__printNetworkInterfaceDetails | awk '{ if(tolower($4) == "ethernet" || tolower($4) == "bond") print $1 };')
			''
			"P=${IYELLOW}Return to the previous menu"
		)
		__printMessage
		if [[ ${#_interfaces[@]} -gt 2 ]]; then
			__getMenuInput 'Interface:' '_interfaces' '_interfaceMaster' || break
			case "${_interfaceMaster}" in
				'P') break;; #Return to the previous menu
				*)
					_interfaceMaster="${_interfaces[$(( ${_interfaceMaster} - 1))]}"
					__printMessage
					if __getInput 'VLAN ID:' '_vlan' '' ${false} '^[1-9][0-9]*$'; then
						if [[ -n "$(__printNetworkInterfaceDetails | awk -v _interfaceMaster="${_interfaceMaster}" -v _vlan="${_vlan}" '{ if($6 == _interfaceMaster && $5 == _vlan) print $1 };')" ]]; then
							__printMessage
							__printMessage "${IRED}VLAN ${IWHITE}${_vlan} ${IRED} already exists for interface ${_interfaceMaster}"
							__printMessage
							__pause
						else
							__addBreadcrumb 'Create New VLAN'
							if ss__createNetworkConfig "${_vlan}" 'vlan' "${_interfaceMaster}"; then
								_vlanInterfaceName="$(__getVLANConfigFileName "${_interfaceMaster}" ${_vlan})"
								_vlanInterfaceName="${_vlanInterfaceName##-*}"
								__startNetworkInterface "${_vlanInterfaceName}" || :
								__printMessage "VLAN ${IWHITE}${_vlan}${RST} for interface ${IWHITE}${_interfaceMaster}${RST} has been created."
							else
								__printMessage
								__printMessage "${IRED}VLAN ${IWHITE}${_vlan}${IRED} for interface ${IWHITE}${_interfaceMaster}${IRED} was not created."
							fi
							__removeBreadcrumb 'Create New VLAN'
						fi
						__printMessage
						__getYesNoInput 'Would you like to create another VLAN interface?' 'Yes' || break
					fi
					;;
			esac
		else
			__printMessage 'No interfaces found to configure for VLAN tagging.'
			__printMessage
			__pause
			break
		fi
	done

	return 0
}

#ss__menu_networking_bonding(BondInterface)
	#Configures BondInterface
function ss__menu_networking_bonding() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local -a _bondActions=('Add Slave' 'Remove Slave' 'Configure IP' '' "R=${IRED}Restart Interface" '' "D=${IRED}Delete Bond" '' "P=${IYELLOW}Return to the previous menu")
	local _bondInterface="${1:?$(__raiseError 'BondInterface is required')}"
	local -a _cursorPosition
	local _interface
	local _selection _slave
	local -a _slaves

	__addBreadcrumb 'Bonding'
	while (( ${true} )); do
		__printTitle 'Bonding' "Bond Interface: ${_bondInterface}"
		__getMenuInput 'Choice:' '_bondActions' '_selection' || break
		case "${_selection}" in
			1) ss__menu_networking_bonding_addslave "${_bondInterface}";; #Add Slave
			2) ss__menu_networking_bonding_removeslave "${_bondInterface}";; #Remove Slave
			3) #Configure IP
				ss__createNetworkConfig "${_bondInterface}" 'bond' || __printMessage "${IRED}Configuration was not saved."
				__pause
				;;
			'D') #Delete Bond
				__printTitle 'Delete Bond Interface'
				__printNetworkInterfaceDetails ${true} | awk -v _bondInterface="${_bondInterface,,}" '{ if(NR == 1 || tolower($6) == _bondInterface) { print $0 }; };' | column -t -s $'\t'
				__printMessage
				if __getYesNoInput "Are you sure you want to delete bond '${_bondInterface}'" "${IRED}No"; then
					__printMessage
					for _interface in $(__printNetworkInterfaceDetails | awk -v _bondInterface="${_bondInterface,,}" '{ if(tolower($6) == _bondInterface) print $1 };' | sort -u); do
						__printMessage "Removing Interface ${IWHITE}${_interface}${RST} ... " ${false}
						_cursorPosition=($(__getCursorPosition)); __printMessage
						__stopNetworkInterface "${_interface}" || : #Stop Interface
						__removeFile "${SYSCONFIG_NETWORK_SCRIPTS}/ifcfg-${_interface}"
						__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done"
						__printMessage
					done

					__stopNetworkInterface "${_bondInterface}" || : #Stop interface
					__removeFile "${SYSCONFIG_NETWORK_SCRIPTS}/ifcfg-${_bondInterface}"
					echo "-${_bondInterface}" > /sys/class/net/bonding_masters 2>/dev/null || :
					__printMessage
					__printMessage "Bond interface ${IWHITE}${_bondInterface}${RST} removed."
					__printMessage
					__pause
					break
				fi
				;;
			'P') break;; #Return to the previous Menu
			'R')
				__printMessage
				__printMessage "${IRED}You could be disconnected by restarting this interface."
				if __getYesNoInput "Do you want to restart ${_bondInterface}?" "${IRED}No"; then
					__printMessage
					__restartNetworkInterface "${_bondInterface}" || :
					__printMessage
					__pause
				fi
				;;
		esac
	done
	__removeBreadcrumb 'Bonding'
}

#ss__menu_networking_bonding_addslave(BondInterface)
function ss__menu_networking_bonding_addslave() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _bondInterface="${1:?$(__raiseError 'BondInterface is required')}"
	local _selection _slave
	local -a _slaves
	local IFS

	__addBreadcrumb 'Bonding'
	while (( ${true} )); do
		IFS=$'\n'
		_slaves=(
			$(__printNetworkInterfaceDetails ${true} | awk 'BEGIN {FS="\t"; OFS="\t"}; { if(NR == 1 || tolower($4) == "ethernet") { print $1, $7 } };' | column -t -s $'\t' || :)
			''
			"P=${IYELLOW}Return to the previous menu"
		)
		unset IFS
		__printTitle 'Add Slave' "Bond Interface: ${_bondInterface}"
		if [[ ${#_slaves[@]} -gt 3 ]]; then
			_slaves[0]="==${_slaves[0]}"
			__getMenuInput 'Choice:' '_slaves' '_selection' || break
			case "${_selection}" in
				'P') break;; #Return to the previous menu
				*) #Should be an ethernet interface
					_slave="$(__removeEscapeCodes "${_slaves[${_selection}]}" | awk '{print $1}')"
					if ss__createNetworkConfig "${_slave}" 'slave' "${_bondInterface}"; then
						if ip -o link show dev "${_bondInterface}" 2>&1 | grep -q -i 'up' && (ip -o link show dev "${_slave}" | grep -q -i 'down' || __getYesNoInput 'Would you like to activate this interface now?' 'Yes'); then
							sysctl -q -w kernel.printk='3 4 1 7' #Disable warnings that are likely about to happen.
							ip link set down dev "${_slave}" || :
							__stopNetworkInterface "${_slave}" #Stop interface
							echo "+${_slave}" 2>/dev/null > /sys/class/net/${_bondInterface}/bonding/slaves || :
							__printMessage "Added ${IWHITE}${_slave}${RST} to bond interface ${_bondInterface} as slave interface."
						else
							__printMessage "Configured ${_slave} as slave for bond interface ${_bondInterface}."
							__printMessage 'Reboot or restart networking for this change to take effect.'
							ss_RESTART_NETWORKING=${true}
						fi
					else
						__printMessage "${IRED}Failed to add ${IWHITE}${_slave}${IRED} to ${IWHITE}${_bondInterface}${IRED} as slave to interface."
					fi
					__printMessage
					__pause
					;;
			esac
		else
			__printMessage 'No interfaces to add'
			__printMessage
			__pause
			break
		fi
	done
	__removeBreadcrumb 'Bonding'
}

#ss__menu_networking_bonding_removeslave(BondInterface)
function ss__menu_networking_bonding_removeslave() {
	[[ ${#} -ne 1 ]] && __raiseWrongParametersError ${#} 1
	local _bondInterface="${1:?$(__raiseError 'BondInterface is required')}"
	local _selection _slave
	local -a _slaves
	local IFS

	while (( ${true} )); do
		IFS=$'\n'
		_slaves=(
			$(__printNetworkInterfaceDetails ${true} | awk -v _bondInterface="${_bondInterface}" 'BEGIN {FS="\t"; OFS="\t"}; { if(NR == 1 || (tolower($4) == "bond" && tolower($6) == _bondInterface)) { print $1, $7 } };' | column -t -s $'\t' || :)
			''
			"P=${IYELLOW}Return to the previous menu"
		)
		unset IFS
		__printTitle 'Remove Slave' "Bond Interface: ${_bondInterface}"
		if [[ ${#_slaves[@]} -gt 3 ]]; then
			_slaves[0]="==${_slaves[0]}"
			__getMenuInput 'Choice:' '_slaves' '_selection' || break
			case "${_selection}" in
				'P') #Return to the previous menu
					break;;
				*)
					_slave="$(__removeEscapeCodes "${_slaves[${_selection}]}" | awk '{print $1}')"
					__printMessage
					if __getYesNoInput "Are you sure you want to remove ${_slave} from bond ${_bondInterface}?" "${IRED}No"; then
						__printMessage
						__printMessage "Removing interface ${IWHITE}${_slave}${RST} from bond interface ${IWHITE}${_bondInterface}${RST} ... " ${false}
						_cursorPosition=($(__getCursorPosition)); __printMessage
						__stopNetworkInterface "${_slave}" 2>&1 >/dev/null || : #Stop interface
						__removeFile "${SYSCONFIG_NETWORK_SCRIPTS}/ifcfg-${_slave}"
						echo "-${_slave}" > /sys/class/net/${_bondInterface}/bonding/slaves 2>/dev/null || :
						__printStatusMessage ${_cursorPosition[*]} "${IGREEN}Done"
						__printMessage
						__pause
					fi
					;;
			esac
		else
			__printMessage 'No slave interfaces to remove'
			__printMessage
			__pause
			break
		fi
	done
}

#ss__menu_preInstallCheck(ReturnOptionEnabled=${true})
	#Displays settings for and run preInstallCheck.sh
function ss__menu_preInstallCheck() {
	local _commandArgs
	local -a _menuOptions
	local _scriptLocation
	local _selection
	local -i _returnEnabled=${1:-${true}}
	local _printMenuComments=${PRINT_MENU_COMMENTS}

	if [[ -f "$(__getDirectoryName)/preInstallCheck.sh" ]]; then
		_scriptLocation="$(__getDirectoryName)"
	elif [[ -f "${ss_STAGING_DIRECTORY}/preInstallCheck.sh" ]]; then
		_scriptLocation="${ss_STAGING_DIRECTORY}"
	elif $(which preInstallCheck.sh 2>&1 >/dev/null); then
		_scriptLocation="$(__getDirectoryName "$(which preInstallCheck.sh)")"
	fi

	if [[ -f "${_scriptLocation}/preInstallCheck.sh" ]]; then
		while (( ${true} )); do
			_menuOptions=(
				"${IPURPLE}Quiet Mode${RST}:  $((( pic_QUIET_MODE )) && printf "${IGREEN}Enabled" || printf "${IRED}Disabled")"
				"##When enabled, output will only show ${IYELLOW}warnings${RST} and ${IRED}errors${RST}"
				'##'
				"${IPURPLE}Skip Network Check${RST}:  $((( pic_SKIP_NETWORK_CHECKS )) && printf "${IGREEN}True" || printf "${IRED}False")"
				'##Do not run network (TCP port) checks'
				'##'
				"${IPURPLE}Create Log${RST}:  $((( pic_CREATE_LOG )) && printf "${IGREEN}Enabled" || printf "${IRED}Disabled")"
				'##Log report also to file. Lof file will be saved in /tmp/'
				'##'
				"${IPURPLE}Zombie Mode${RST}:  $((( pic_ZOMBIE_MODE )) && printf "${IGREEN}${pic_ZOMBIE_MODE}" || printf "${IRED}Disabled")"
				"##Use this when a network has high latency or node response is slow due to low resource allocation"
				'##  N is max wait time before we declare a check as failed.'
				'##  When disabled it uses low values as default.'
				'##'
				"${IPURPLE}Force sync NTP${RST}:  $((( pic_FORCE_SYNC_NTP )) && printf "${IGREEN}True" || printf "${IRED}False")"
				'##Start and/or force synchronize NTP on all nodes.'
				'##NOTE: On force sync, time-leap may be large and possibly interruptive'
				'__Script Settings'
				"${IPURPLE}Staging Directory${RST}:  ${ICYAN}${ss_STAGING_DIRECTORY}$([[ -d "${ss_STAGING_DIRECTORY}" ]] || printf " ${IRED}(Not Found)")"
				"${IPURPLE}Survey File${RST}:  ${ICYAN}${ss_SURVEY_FILE}$([[ -f "$(ss__getSurveyFileName)" ]] || printf " ${IRED}(Not Found)")"
				''
				"H=$((( PRINT_MENU_COMMENTS )) && printf "Hide" || printf "Display") help information"
				''
				"R=${IGREEN}Run Pre-Install Checks"
				''
				"$((( _returnEnabled )) || printf '%s' '--')P=${IYELLOW}Return to the previous menu"
				"$((( ! _returnEnabled )) || printf '%s' '--')X=${IRED}Exit"
			)

			__printTitle 'Pre-installation Checklist' "Using ${_scriptLocation}/preInstallCheck.sh"
			__getMenuInput "Choice: ${IWHITE}" '_menuOptions' '_selection' || return ${?}
			case "${_selection}" in
				'1') __toggleBoolean 'pic_QUIET_MODE';;
				'2') __toggleBoolean 'pic_SKIP_NETWORK_CHECKS';;
				'3') __toggleBoolean 'pic_CREATE_LOG';;
				'4')
					__printMessage
					__printMessage 'Set to 0 to disable and use default timeout values'
					__getInput "Zombie Mode? ${IWHITE}" 'pic_ZOMBIE_MODE' "${pic_ZOMBIE_MODE}" ${false} '^(0|[1-9][0-9]*)$' || __raiseError 'To many failed attempts' 99
					;;
				'5') __toggleBoolean 'pic_FORCE_SYNC_NTP';;
				'6') ss__changeStagingDirectory;;
				'7') ss__changeSurveyFileLocation;;
				'H') __toggleBoolean 'PRINT_MENU_COMMENTS';;
				'R')
					_commandArgs='-c'
					(( pic_QUIET_MODE )) && _commandArgs+=' -q'
					(( pic_SKIP_NETWORK_CHECKS )) && _commandArgs+=' -n'
					(( pic_CREATE_LOG )) && _commandArgs+=' -l'
					(( pic_ZOMBIE_MODE )) && _commandArgs+=" -z${pic_ZOMBIE_MODE}"
					(( pic_FORCE_SYNC_NTP )) && _commandArgs+=' -f'

					ss__installPackage 'sshpass' || :

					__printTitle 'Pre-installation Checklist'
					__logMessage "${_scriptLocation}/preInstallCheck.sh -d \"${ss_STAGING_DIRECTORY}\" -k \"$(ss__getSSHKeyFileName)\" -s \"$(ss__getSurveyFileName)\" ${_commandArgs} -- --system-setup"
					__printDebugMessage "${_scriptLocation}/preInstallCheck.sh -d \"${ss_STAGING_DIRECTORY}\"-k \"$(ss__getSSHKeyFileName)\"  -s \"$(ss__getSurveyFileName)\" ${_commandArgs} -- --system-setup"
					__isDebugEnabled && __pause
					${_scriptLocation}/preInstallCheck.sh -d "${ss_STAGING_DIRECTORY}" -k "$(ss__getSSHKeyFileName)" -s "$(ss__getSurveyFileName)" ${_commandArgs} -- --system-setup
					__pause
					;;
				'P')
					PRINT_MENU_COMMENTS=${_printMenuComments}
					break
					;;
				'X') exit 0;;
			esac
		done
	else
		__printErrorMessage "preInstallCheck.sh was not found in $(__getDirectoryName), ${ss_STAGING_DIRECTORY}, or PATH environment variable."
	fi

	return 0
}

#ss__menu_settings()
	#Display and modify script settings
function ss__menu_settings() {
	local -a _fsTypes=(${!ss_mountOptions[*]})
	local -a _vlanNamingStyles
	local -a _menuOptions
	local _selection

	__addBreadcrumb 'Configure Script Settings'
	while (( ${true} )); do
		_menuOptions=(
			"${IPURPLE}Auto Update${RST}:  $((( ss_AUTO_UPDATE )) && printf "${IGREEN}Enabled" || printf "${IRED}Disabled")"
				'##Automatically check and update script from online when executed\n'
			"${IPURPLE}Use Colors${RST}:  $((( ss_USE_COLORS )) && printf "${IGREEN}Enabled" || printf "${IRED}Disabled")"
				'##Enable/disable the use of color output\n'
			"${IPURPLE}Menu Help${RST}:  $((( PRINT_MENU_COMMENTS )) && printf "${IGREEN}Enabled" || printf "${IRED}Disabled")"
				'**Displays inline information like this for some menu options\n'
			"${IPURPLE}Debug${RST}:  $((( DEBUG )) && printf "${IGREEN}Enabled (${DEBUG})" || printf "${IRED}Disabled")"
				'##Enable/disable debug mode. Typing +debug or -debug at any prompt will increase or decrease the debug level\n'
			"${IPURPLE}Input Attempts${RST}:  ${ICYAN}${INPUT_LIMIT}"
				'##Number of failed input attempts before erroring\n'
			"${IPURPLE}Max Column Width${RST}:  ${ICYAN}${MAX_COLUMN_WIDTH}"
				'##When two column output is displayed, how wide are the columns\n'
			"${IPURPLE}Max Single Column Options${RST}:  ${ICYAN}${MAX_SINGLE_COLUMN_OPTIONS}"
				'##Adjusts how many menu options are displayed in a single column before switching to two columns'
			'__Locations'
			"${IPURPLE}Staging Directory${RST}:  ${ICYAN}${ss_STAGING_DIRECTORY}$([[ -d "${ss_STAGING_DIRECTORY}" ]] || printf " ${IRED}(Not Found)")"
			"${IPURPLE}Survey File${RST}:  ${ICYAN}${ss_SURVEY_FILE}$([[ -f "$(ss__getSurveyFileName)" ]] || printf " ${IRED}(Not Found)")"
			'__SSH Settings'
			"${IPURPLE}SSH Key File${RST}:  ${ICYAN}${ss_SSH_KEY_FILE}$([[ -f "$(ss__getSSHKeyFileName)" ]] || printf " ${IRED}(Not Found)")"
			"${IWHITE}Generate SSH Key File"
			"${IWHITE}Push SSH Key File to cluster nodes"
			"$(__isBeta || printf '%s' '--')__Configure Disks"
			"$(__isBeta || printf '%s' '--')${IPURPLE}File System Type${RST}:  ${ICYAN}${ss_FSTYPE}"
			'__Network Settings'
			"${IPURPLE}VLAN Naming Style${RST}:  ${ICYAN}${VLAN_NAME_TYPE}${RST} (Example: $([[ "${VLAN_NAME_TYPES["${VLAN_NAME_TYPE}"]:0:1}" == '%' ]] && printf "${VLAN_NAME_TYPES["${VLAN_NAME_TYPE}"]}" 'eth0' 10 || printf "${VLAN_NAME_TYPES["${VLAN_NAME_TYPE}"]}" 10))"
				'##Naming style to use for VLAN interfaces'
			''
			'U=Update this script from online'
			''
			"P=${IYELLOW}Return to the previous menu"
			'**' #force Exit to it's own line
			"X=${IRED}Exit"
		)

		__printTitle 'Configure Script Settings'
		__getMenuInput "Choice: ${IWHITE}" '_menuOptions' '_selection' || return ${?}
		case "${_selection}" in
			'1') #Toggle Auto Update
				__toggleBoolean 'ss_AUTO_UPDATE'
				ss__saveSetting 'ss_AUTO_UPDATE'
				;;
			'2') #Toggle Use Colors
				__toggleBoolean 'ss_USE_COLORS'
				(( ss_USE_COLORS )) && __loadColors || __unloadColors
				ss__saveSetting 'ss_USE_COLORS'
				;;
			'3') __toggleBoolean 'PRINT_MENU_COMMENTS' ;; #Toggle Menu Help
			'4') __toggleBoolean 'DEBUG' ;; #Toggle Debug
			'5') #Configure Input Attempts
				__printTitle 'Input Attempts' 'Sets how many failed input attempts before erroring\nDefault: 5\nDisable: -1'
				__getInput 'Input Attempts:' 'INPUT_LIMIT' "${INPUT_LIMIT}" ${false} '^(-1|[1-9][0-9]*)$' && ss__saveSetting 'INPUT_LIMIT'
				;;
			'6') #Max Column Width
				__printTitle 'Max Column Width'
				__getInput 'Max column width:' 'MAX_COLUMN_WIDTH' "${MAX_COLUMN_WIDTH}" ${false} '^[1-9][0-9]*' && ss__saveSetting 'MAX_COLUMN_WIDTH'
				;;
			'7') #Max Items for single column menu
				__printTitle 'Max Single Column'
				__getInput 'Max single column options:' 'MAX_SINGLE_COLUMN_OPTIONS' "${MAX_SINGLE_COLUMN_OPTIONS}" ${false} '^[1-9][0-9]*' && ss__saveSetting 'MAX_SINGLE_COLUMN_OPTIONS'
				;;
			'8') ss__changeStagingDirectory ;; #Change Staging Directory
			'9') ss__changeSurveyFileLocation ;; #Change Survey File Location
			'10') ss__changeSSHKeyFileLocation ;; #Change SSH Key File Location
			'11') #Generate SSH Key File
				__printTitle 'Generate SSH Key File' "Save Location: $(ss__getSSHKeyFileName)"
				if ss__generateSSHKeyFile "$(ss__getSSHKeyFileName)"; then
					__printMessage
					if __getYesNoInput 'Install public key on cluster nodes?' 'Yes'; then
						ss__installSSHKeyFile "$(ss__getSSHKeyFileName)" || __printErrorMessage 'Failed to install ssh key'
						__pause
					fi
				fi
				;;
			'12') #Push SSH Key File to cluster nodes
				__printTitle 'Install SSH Key File' "Save Location: $(ss__getSSHKeyFileName)"
				ss__installSSHKeyFile "$(ss__getSSHKeyFileName)" || __printErrorMessage 'Failed to install ssh key'
				__printMessage
				__pause
				;;
			'13') #Change File System Format
				__printTitle 'Disk File System Format' 'Change the file system used to configure disks for HyperStore'
				__printMessage "${IYELLOW}Currently only ext4 is supported by Cloudian."
				__printMessage
				if __getMultipleChoiceInput 'Which filesystem type do you want to use?' '_fsTypes' '_selection' "${ss_FSTYPE}"; then
					ss_FSTYPE="${_selection,,}"
					ss__saveSetting 'ss_FSTYPE'
				fi
				;;
			'14') #Change VLAN Naming Style
				_vlanNamingStyles=()
				for _selection in ${!VLAN_NAME_TYPES[*]}; do
					_vlanNamingStyles+=("${_selection}" "**Example: $([[ "${VLAN_NAME_TYPES["${_selection}"]:0:1}" == '%' ]] && printf "${VLAN_NAME_TYPES["${_selection}"]}" 'eth0' 10 || printf "${VLAN_NAME_TYPES["${_selection}"]}" 10)" '')
				done
				_vlanNamingStyles+=("P=${IYELLOW}Return to the previous menu")
				__printTitle 'VLAN Naming Style' 'Change the naming style used to create new VLAN interfaces'
				__getMenuInput 'VLAN Naming Style?' '_vlanNamingStyles' '_selection' '' ${INPUT_RETURN_STYLE_SELECTED_INDEX} && {
					[[ ${_selection} -eq $((${#_vlanNamingStyles[@]} - 1)) ]] && continue
					VLAN_NAME_TYPE=${_vlanNamingStyles[${_selection}]}
					__printDebugMessage "Saving VLAN_NAME_TYPE with '${VLAN_NAME_TYPE}'"
					ss__saveSetting 'VLAN_NAME_TYPE'
				}
				;;
			'U') ss__onlineUpdate || __pause ;; #Update Script
			'P') break ;; #Previous Menu
			'X') exit 0 ;; #Exit Script
		esac
	done
	__removeBreadcrumb 'Configure Script Settings'

	return 0
}

#ss__menu_surveyFile()
	#Create/modifies the ${ss_SURVEY_FILE}
	#Return Codes:
	#Exit Codes:	1
function ss__menu_surveyFile() {
	local -a _menuOptions
	local _selection

	if [[ ! -f "$(ss__getSurveyFileName)" ]]; then
		__printTitle 'Survey File' "Using '${IWHITE}$(ss__getSurveyFileName)${RST}'"
		__getYesNoInput 'Would you like to create a survey file now?' 'Yes' || return 0
		_selection='C'
	fi

	while (( ${true} )); do
		_menuOptions=(
			'Show Existing Entries' #0
			'Add New Entries' #1
			'Edit Existing Entries' #2
			'Remove Existing Entries' #3
			'' #4
			'C=Create New File' #5
			"D=${IRED}Delete Existing File" #6
			'' #7
			"**${IRED}Invalid Entries Found In Survey File. Please correct manually." #8
			'' #9
			"P=${IYELLOW}Return to the previous menu" #10
		)

		if [[ -f "$(ss__getSurveyFileName)" ]]; then
			_menuOptions[5]="--${_menuOptions[5]}"
		else
			_menuOptions[0]="--${_menuOptions[0]}"
			_menuOptions[1]="--${_menuOptions[1]}"
			_menuOptions[2]="--${_menuOptions[2]}"
			_menuOptions[3]="--${_menuOptions[3]}"
			_menuOptions[4]="--${_menuOptions[4]}"
			_menuOptions[6]="--${_menuOptions[6]}"
			_menuOptions[7]="--${_menuOptions[7]}"
			_menuOptions[8]="--${_menuOptions[8]}"
		fi

		if ss__checkInvalidSurveyFileEntries 2>/dev/null; then
			_menuOptions[7]="--${_menuOptions[7]}"
			_menuOptions[8]="--${_menuOptions[8]}"
		fi

		__printTitle 'Survey File' "Using '${IWHITE}$(ss__getSurveyFileName)${RST}'"
		[[ ! -f "$(ss__getSurveyFileName)" && "${_selection}" == 'C' ]] || __getMenuInput 'Choice:' '_menuOptions' '_selection' || return ${?}
		__addBreadcrumb 'Survey File'
		case "${_selection}" in
			'1') #Show Entries
				__printTitle 'Node Entries'
				ss__printSurveyFileEntries ${true} || __printMessage 'No entries found'
				__printMessage
				__pause
				;;
			'C') #Create New File
				__printTitle 'Create Survey File'
				__createDirectory "$(__getDirectoryName "$(ss__getSurveyFileName)")" || __raiseError 'Failed to create directory' 1
				__createFile "$(ss__getSurveyFileName)" || __raiseError 'Failed to create file' 1
				__printMessage
				__getYesNoInput 'Would you like to add entries now?' 'Yes' || continue
				;& #Continue to add entry
			'2') #Add Entry
				while ! ss__getSurveyFileEntryInputs ${true}; do
					__getYesNoInput 'Would you like to try again?' "${IRED}No" || break
				done
				;;
			'3') #Edit Entry
				while ! ss__editSurveyFileEntry; do
					__getYesNoInput 'Would you like to try again?' "${IRED}No" || break
				done
				;;
			'4') #Remove Entry
				while ! ss__removeSurveyFileEntry; do
					__getYesNoInput 'Would you like to try again?' "${IRED}No" || break
				done
				;;
			'D') #Delete Existing File
				__printTitle 'Delete Survey File'
				if __getYesNoInput 'Are you sure you want to delete your survey file?' "${IRED}No"; then
					__printMessage
					__removeFile "$(ss__getSurveyFileName)" || __raiseError 'Failed to delete file' 1
				fi
				__printMessage
				__pause
				;;
			'P') break ;; #Previous Menu
		esac
	done

	__removeBreadcrumb 'Survey File'

	return 0
}

### ############## ###

#main code executed only if this file wasn't sourced
if ! __isSourced; then
	__logMessage "Starting $(__getFileName)"
	ss__menu_main "${@}"
else
	__isBeta || __logMessage "Successfully sourced $(__getFileName) by ${0}"
fi