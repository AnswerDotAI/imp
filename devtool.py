"Build and release helpers for Imp, run from a kernel session."

import re

from fastcore.utils import *
from fastcocoa.swifttool import build_app

__all__ = ['imp_dir', 'imp_plist', 'imp_version', 'build_imp']

imp_dir = Path(__file__).parent  # the recipe lives in the repo it builds

# One entry per permission Imp can ask for, keyed by Info.plist name (NS{k}UsageDescription). macOS kills
# the process outright when a category is requested and its string is missing, and shows the string in the dialog.
_usage = dict(Microphone='record audio', Camera='use the camera', SpeechRecognition='transcribe speech',
    Contacts='read your contacts', CalendarsFullAccess='manage your calendars', AppleEvents='control other apps',
    RemindersFullAccess='manage your reminders', PhotoLibrary='access your photo library')
imp_plist = {f'NS{k}UsageDescription': f'so programs you run through Imp can {v}' for k,v in _usage.items()}


def imp_version():
    "The version Imp reports, which is the one the bundle must claim"
    return re.search(r'impVersion = "([^"]+)"', (imp_dir/'Sources/Imp/main.swift').read_text())[1]


def build_imp(
    hardened:bool=False # Hardened runtime blocks TCC prompts without a per-resource entitlement (see Imp's DEV.md)
):
    "Build, sign, and zip Imp, so its bundle id, version, usage strings, and signing flags live in one place"
    ver,icon = imp_version(),imp_dir/'art/icon/AppIcon.icon'
    return build_app(imp_dir, 'com.answerdotai.imp', hardened=hardened, app_icon=icon, deployment_target='14.0',
        CFBundleShortVersionString=ver, CFBundleVersion=ver, **imp_plist)
