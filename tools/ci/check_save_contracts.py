#!/usr/bin/env python3
"""Enforce save ownership, native section contracts, and Narrative layouts."""
from pathlib import Path
import argparse
import re
from check_save_section_contracts import REGISTRY as CPP_REGISTRY, violations as cpp_section_violations
from narrative_save_layout import SOURCE as NARRATIVE_SOURCE, narrative_violations

ROOT=Path(__file__).resolve().parents[2]
BASE='Project/project-keynes/scripts/game/'

def violations(root):
    errors=[]
    specs=[('country_state.gd','pkcn',('capture_ecp2','restore_ecp2','native_economy_ecp2'), 'simulation_runtime'),
           ('economy_state.gd','ecp2',('restore_country_runtime_checkpoint','native_country_pkcn'), 'pkcn')]
    for filename, section, forbidden, dependency in specs:
        text=(root/(BASE+'save_modules/'+filename)).read_text()
        code=re.sub(r'#.*','',text)
        # Dependency names in archive_contract are metadata, not byte access.
        implementation = code[code.find("\nfunc "):]
        foreign_section = 'ecp2' if filename == 'country_state.gd' else 'pkcn'
        if re.search(r'\b' + foreign_section + r'\b', implementation):
            errors.append(filename+' foreign section byte access '+foreign_section)
        for token in forbidden:
            if re.search(r'\b'+token+r'\b',code): errors.append(filename+' foreign archive access '+token)
        if filename=='economy_state.gd' and re.search(r'context\s*(?:\.\s*country\b|\[\s*["\x27]country["\x27])',code):
            errors.append(filename+' foreign owner capability')
        for token in ('archive_contract','"id"','"version"','"sections"','"restore_after"','"readable_versions"','"write"','"restore"'):
            if token not in code: errors.append(filename+' missing contract '+token)
        if '"'+section+'"' not in code or '"'+dependency+'"' not in code:
            errors.append(filename+' contract identity/dependency missing')
    composition=(root/(BASE+'world_state_modules.gd')).read_text()
    for owner in ('CountryState','EconomyState'):
        if '_owned_provider(adapters[' not in composition or owner+'.archive_contract(' not in composition:
            errors.append('composition bypasses '+owner+' contract')
    if (root / CPP_REGISTRY).is_file():
        errors.extend(cpp_section_violations(root))
    elif (root / NARRATIVE_SOURCE).is_file():
        errors.append(f'missing native save section registry {CPP_REGISTRY}')
    if (root / CPP_REGISTRY).is_file() or (root / NARRATIVE_SOURCE).is_file():
        errors.extend(narrative_violations(root))
    return errors

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,default=ROOT);a=p.parse_args()
    errors=violations(a.root)
    for e in errors:print(e)
    print(f'save contracts: 2 script owners, 12 C++ domains and Narrative layouts, {len(errors)} violations')
    return bool(errors)
if __name__=='__main__':raise SystemExit(main())
