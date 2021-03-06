/*
 * chacl.swift
 * chacl
 *
 * Created by François Lamboley.
 */

import Foundation
import OpenDirectory

import ArgumentParser
import CLTLogger
import Logging



/* Useful: https://opensource.apple.com/source/Libc/Libc-583/include/sys/acl.h.auto.html */
@main
struct Chacl : ParsableCommand {
	
	static var configuration = CommandConfiguration(
		commandName: "chacl",
		abstract: "Apply ACLs in a hierarchy of files and folders given a list of rules.",
		discussion: """
		The config file format is as follow:
		   One PATH per line (if a path is present more than once, the latest entry will win)
		   Each line must have the following format: `([u|g]:[r|rw]:USER_OR_GROUP_NAME:)*:PATH`
		""")
	
	@Flag
	var dryRun: Bool = false
	
	@Flag
	var verbose: Bool = false
	
	@Option
	var adminUsername: String
	
	@Argument
	var configFilePath: String
	
	func run() throws {
		LoggingSystem.bootstrap{ _ in CLTLogger() }
		
		/* Commented because the compiler knows KAUTH_GUID_SIZE == 16 at compile
		 * time and thus complains w/ a warning the else part of the guard will
		 * never be executed…
		 * Instead we do the opposite, and (hopefully) trigger a warning if
		 * KAUTH_GUID_SIZE is not 16! I don’t know if a static check from the
		 * compiler is possible, but it does not seem to be. (It is technically
		 * possible; KAUTH_GUID_SIZE is a #define, but I don’t think it’s
		 * implemented in the compiler.)
		 * This is indeed not the same thing! But I don’t want a warning in my
		 * code, and realistically KAUTH_GUID_SIZE will never be != 16. */
//		guard KAUTH_GUID_SIZE == 16 else {
//			throw SimpleError(message: "The auth GUID has not the expected size (thus is probably not a UUID), so we can’t run. At all. Bye.")
//		}
		if KAUTH_GUID_SIZE == 16 {
			_ = "not an empty if! The auth GUID has not the expected size (thus is probably not a UUID), so you’ll probably run into weird issues…"
		}
		
		let fm = FileManager.default
		
		let odSession = ODSession.default()
		let odNode = try ODNode(session: odSession, type: ODNodeType(kODNodeTypeAuthentication))
		let adminRecord = try odNode.record(withRecordType: kODRecordTypeUsers, name: adminUsername, attributes: [kODAttributeTypeGUID])
		let everyoneRecord = try odNode.record(withRecordType: kODRecordTypeGroups, name: "everyone", attributes: [kODAttributeTypeGUID])
		let spotlightRecord = try odNode.record(withRecordType: kODRecordTypeUsers, name: "spotlight", attributes: [kODAttributeTypeGUID])
		guard let adminGUID = try (adminRecord.values(forAttribute: kODAttributeTypeGUID).onlyElement as? String).flatMap({ UUID(uuidString: $0) }),
				let everyoneGUID = try (everyoneRecord.values(forAttribute: kODAttributeTypeGUID).onlyElement as? String).flatMap({ UUID(uuidString: $0) }),
				let spotlightGUID = try (spotlightRecord.values(forAttribute: kODAttributeTypeGUID).onlyElement as? String).flatMap({ UUID(uuidString: $0) })
		else {
			throw SimpleError(message: "Zero or more than one value, or invalid UUID string for attribute kODAttributeTypeGUID for the a user or group; cannot continue.")
		}
		
		let adminACLConf = try AclConfig(adminACLWithUUID: adminGUID)
		let everyoneACLConf = try AclConfig(denyEveryoneExecuteACLWithUUID: everyoneGUID)
		
		/* Parsing the config */
		let configs: [URL: AclConfig]
		do {
			let fh: FileHandle
			let baseURLForPaths: URL
			if configFilePath == "-" {
				fh = FileHandle.standardInput
				baseURLForPaths = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
			} else {
				/* No need to close the FileHandle, it will be closed on dealloc. */
				fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: configFilePath))
				baseURLForPaths = URL(fileURLWithPath: configFilePath).deletingLastPathComponent()
			}
			let aclConf = try ChaclConfigEntry.parse(config: fh, baseURLForPaths: baseURLForPaths, logger: logger)
			configs = try Dictionary(grouping: aclConf, by: { URL(fileURLWithPath: $0.absolutePath) })
				.mapValues{ confEntry in
					guard let confEntry = confEntry.onlyElement else {
						throw SimpleError(message: "Internal logic error (ChaclConfigEntry.parse should have cleaned up double entries for one file).")
					}
					return try AclConfig(chaclConfig: confEntry, odNode: odNode)
				}
		}
		
		/* Let’s process these ACLs!
		 *
		 * We want to treat longer paths at the end to optimize away all path that
		 * have a parent which include them. Beyond optimization, this is
		 * important because we add a deny everyone ACE at the end of the ACE list
		 * and want this ACE to be added once.
		 *
		 * Because the paths are absolute (and dropped of all the .. components,
		 * and stripped, etc. using realpath), treating longer paths at the end
		 * should works in most of the cases. */
		var treated = Set<String>()
		for url in configs.keys.sorted(by: { $0.absoluteURL.path.count < $1.absoluteURL.path.count }) {
			let path = url.absoluteURL.path
			
			guard !treated.contains(where: { path.hasPrefix($0 + "/") }) else {continue}
			treated.insert(path)
			
			if verbose {
				print((dryRun ? "** DRY RUN ** " : "") + "Setting ACLs recursively on all files and folders in \(path)")
			}
			
			/* Let’s create a directory enumerator to enumerate all the files and
			 * folder in the path being treated. */
			let url = URL(fileURLWithPath: path)
			guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileResourceTypeKey, .isSystemImmutableKey, .isUserImmutableKey]) else {
				throw SimpleError(message: "Cannot get directory enumerator for url \(url)")
			}
			
			/* Actually setting the ACLs */
			try setACLs(on: url, whitelist: [spotlightGUID], adminACLConfs: [adminACLConf], denyExecuteConf: everyoneACLConf, aclConfs: configs, fileManager: fm, isRoot: true, dryRun: dryRun) /* We must first call for the current path itself: the directory enumerator does not output the source. */
			while let subURL = enumerator.nextObject() as! URL? {
				try setACLs(on: subURL, whitelist: [spotlightGUID], adminACLConfs: [adminACLConf], denyExecuteConf: everyoneACLConf, aclConfs: configs, fileManager: fm, isRoot: false, dryRun: dryRun)
			}
		}
	}
	
	/** Must not be accessed before the logging system has been bootstrapped. */
	private static var logger: Logger = {
		var ret = Logger(label: "me.frizlab.chacl")
		ret.logLevel = .warning
		return ret
	}()
	/** Must not be accessed before the logging system has been bootstrapped. */
	private var logger: Logger {return Self.logger}
	
	private func iterateMatchingConfs(url: URL, confs: [URL: AclConfig], _ block: (_ conf: AclConfig, _ isRoot: Bool) throws -> Void) rethrows {
		var curURL = URL(fileURLWithPath: "/")
		
		/* These asserts justify what we do next in the for. */
		assert(url.pathComponents.first == "/")
		assert(curURL.appendingPathComponent("/").pathComponents == ["/"])
		for currentPathComponent in url.pathComponents {
			curURL = curURL.appendingPathComponent(currentPathComponent)
			if let conf = confs[curURL.standardizedFileURL] {try block(conf, curURL.standardizedFileURL == url.standardizedFileURL)}
		}
	}
	
	private func setACLs(on url: URL, whitelist: Set<UUID>, adminACLConfs: [AclConfig], denyExecuteConf: AclConfig, aclConfs: [URL: AclConfig], fileManager fm: FileManager, isRoot: Bool, dryRun: Bool) throws {
		let path = url.absoluteURL.path
		let urlResourceValues = try url.resourceValues(forKeys: [.fileResourceTypeKey, .isSystemImmutableKey, .isUserImmutableKey])
		guard let fileResourceType = urlResourceValues.fileResourceType else {
			throw SimpleError(message: "Cannot get file type of URL \(url)")
		}
		let isUserImmutable = urlResourceValues.isUserImmutable ?? false
		let isSystemImmutable = urlResourceValues.isSystemImmutable ?? false
		if urlResourceValues.isUserImmutable == nil {logger.warning("cannot get user immutable flags on file at path \(path)")}
		if urlResourceValues.isSystemImmutable == nil {logger.warning("cannot get system immutable flags on file at path \(path)")}
		
		guard fileResourceType == .directory || fileResourceType == .regular else {
			if verbose {
				print("ignored non-regular and non-directory path \(path)")
			}
			return
		}
		
		var acl: acl_t!
		if let currentACL = acl_get_link_np(path, ACL_TYPE_EXTENDED) {
			acl = currentACL
		} else {
			guard errno == ENOENT else {throw SimpleError(message: "Cannot read ACLs for path \(path); got error number \(errno)")}
			acl = acl_init(21)
		}
		defer {acl_free(UnsafeMutableRawPointer(acl))}
		
		/* We get the external representation of the ACL before modifications. */
		let externalACLRepresentationBeforeModif = try getExternalRepresentation(of: acl)
		
		let isDir = fileResourceType == .directory
		/* Remove all ACLs except whiltelisted */
		_ = try removeACLs(from: acl, whitelist: whitelist, pathForLogs: path)
		/* Add admin ACL */
		try adminACLConfs.forEach{ try _ = $0.addACLEntries(to: &acl, isFolder: isDir, isRoot: isRoot) }
		/* Add ACLs from confs */
		try iterateMatchingConfs(url: url, confs: aclConfs, { conf, isRoot in
			_ = try conf.addACLEntries(to: &acl, isFolder: isDir, isRoot: isRoot)
		})
		/* Add deny execute ACL */
		_ = try denyExecuteConf.addACLEntries(to: &acl, isFolder: isDir, isRoot: isRoot)
		
		/* Now let’s get the representation after the modifications. We then check
		 * if the representation is different before actually trying to modify the
		 * filesystem. Doc does not say reprensentation of two ACLs representing
		 * the same permission will always produce the same result but we can
		 * guess it does, and in any case, two same representation will definitely
		 * represent the same ACL. */
		let externalACLRepresentationAfterModif = try getExternalRepresentation(of: acl)
		
		if externalACLRepresentationBeforeModif != externalACLRepresentationAfterModif {
			if dryRun {
				print("** DRY RUN ** setting ACLs to file \(path)")
			} else {
				/* Deal with the immutable flags */
				if isSystemImmutable || isUserImmutable {
					if verbose {print("removing system and/or user immutable flag on file at path \(path)")}
					changeFlagsOrPrintError({ UInt32(Int32($0) & ~(SF_IMMUTABLE|UF_IMMUTABLE)) }, url: url, urlResourceValues: urlResourceValues)
				}
				
				/* Set ACL */
				if verbose {print("setting ACLs to file \(path)")}
				if acl_set_link_np(path, ACL_TYPE_EXTENDED, acl) != 0 {
//					throw SimpleError(message: "cannot set ACL on file at path \(path) (\(errno))")
					logger.error("cannot set ACL on file at path \(path): \(String(cString: strerror(errno)))")
				}
				
				/* Put the immutable flag back */
				if isSystemImmutable || isUserImmutable {
					if verbose {print("putting back system and/or user immutable flag on file at path \(path)")}
					changeFlagsOrPrintError({ $0 | UInt32((isSystemImmutable ? SF_IMMUTABLE : 0) | (isUserImmutable ? UF_IMMUTABLE : 0)) }, url: url, urlResourceValues: urlResourceValues)
				}
			}
		}
	}
	
	/* Technically can fail, but we ignore the error, the does not throw. */
	private func changeFlagsOrPrintError(_ flagBlock: (UInt32) -> UInt32, url: URL, urlResourceValues: URLResourceValues) {
		let path = url.absoluteURL.path
		/* Funny thing, the isSystemImmutableKey key is documented as being rw,
		 * but in Swift, the isSystemImmutable is ro. So we’ll use the
		 * underlying syscalls (this binary should be called as root, so it
		 * should have the permission).
		 * As long as we do it for the system immutable flag, let’s also do it
		 * for the user one here… */
		let errormsg = url.withUnsafeFileSystemRepresentation{ cpath -> String? in
			var statresults = stat()
			/* First let’s get the current flags. */
			guard lstat(cpath, &statresults) == 0 else {
				return "cannot lstat"
			}
			/* Then we XOR the immutable flags. */
			statresults.st_flags = flagBlock(statresults.st_flags)
			guard chflags(cpath, statresults.st_flags) == 0 else {
				return "cannot chflags"
			}
			return nil
		}
		if let errormsg = errormsg {
			logger.error("cannot remove system immutable flag on file at path \(path): \(errormsg). ACL set will probably fail.")
		}
	}
	
	private func getExternalRepresentation(of acl: acl_t) throws -> Data {
		let size = acl_size(acl)
		guard size >= 0 else {
			throw SimpleError(message: "cannot get size of external representation of ACL")
		}
		var buffer = Data(repeating: 0, count: size)
		let actualSize = buffer.withUnsafeMutableBytes{ bytes in
			return acl_copy_ext_native(bytes.baseAddress, acl, size)
		}
		guard actualSize >= 0 else {
			throw SimpleError(message: "cannot get external representation of ACL")
		}
		return buffer[0..<actualSize]
	}
	
	private func removeACLs(from acl: acl_t, whitelist: Set<UUID>, pathForLogs: String) throws -> Bool {
		var modified = false
		var currentACLEntry: acl_entry_t?
		var currentACLEntryId = ACL_FIRST_ENTRY.rawValue
		/* The only error possible is invalid entry id (either completely invalid
		 * or next id after last entry has been reached).
		 * We know we’re giving a correct entry id, so if we get an error we have
		 * reached the latest entry! */
		while acl_get_entry(acl, currentACLEntryId, &currentACLEntry) == 0 {
			let currentACLEntry = currentACLEntry! /* No error from acl_get_entry: the entry must be filled in and non-nil */
			defer {currentACLEntryId = ACL_NEXT_ENTRY.rawValue}
			
			/* Getting ACL entry tag */
			var currentACLEntryTagType = ACL_UNDEFINED_TAG
			guard acl_get_tag_type(currentACLEntry, &currentACLEntryTagType) == 0 else {
				throw SimpleError(message: "Cannot get ACL Entry Tag Type")
			}
			guard currentACLEntryTagType == ACL_EXTENDED_ALLOW || currentACLEntryTagType == ACL_EXTENDED_DENY else {
				throw SimpleError(message: "Unknown ACL tag type \(currentACLEntryTagType) for path \(pathForLogs); bailing out")
			}
			
			/* The man of acl_get_qualifier says if the tag type is
			 * ACL_EXTENDED_ALLOW or ACL_EXTENDED_DENY, the returned pointer will
			 * point to a guid_t */
			guard let userOrGroupGUIDPointer = acl_get_qualifier(currentACLEntry)?.assumingMemoryBound(to: guid_t.self) else {
				throw SimpleError(message: "Cannot fetch userOrGroupGUID GUID for path \(pathForLogs)")
			}
			defer {acl_free(userOrGroupGUIDPointer)}
			guard let userOrGroupGUID = UUID(guid: userOrGroupGUIDPointer.pointee) else {
				throw SimpleError(message: "Cannot convert guid_t to UUID (weird though) for path \(pathForLogs)")
			}
			guard !whitelist.contains(userOrGroupGUID) else {
				continue
			}
			
			/* Source code https://opensource.apple.com/source/Libc/Libc-825.26/posix1e/acl_entry.c.auto.html
			 * confirms it is valid to get next entry when we have deleted one. */
			acl_delete_entry(acl, currentACLEntry)
			modified = true
		}
		return modified
	}
	
	
	/* Must be a class to have a deinit, because we keep refs to acl_t pointers
	 * and need to free them when we are dealloc’d. */
	private class AclConfig {
		
		/* All from chmod man. There is ACL_SYNCHRONIZE from the headers, don’t
		 * know what it does. */
		static let allPermsForFiles   = [ACL_DELETE, ACL_READ_ATTRIBUTES, ACL_WRITE_ATTRIBUTES, ACL_READ_EXTATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_READ_SECURITY, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER, ACL_READ_DATA, ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_EXECUTE]
		static let allPermsForFolders = [ACL_DELETE, ACL_READ_ATTRIBUTES, ACL_WRITE_ATTRIBUTES, ACL_READ_EXTATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_READ_SECURITY, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER, ACL_LIST_DIRECTORY, ACL_SEARCH, ACL_ADD_FILE, ACL_ADD_SUBDIRECTORY, ACL_DELETE_CHILD]
		
		init(adminACLWithUUID uuid: UUID) throws {
			refACLForFile = acl_init(1)
			refACLForFolder = acl_init(1)
			try Self.addEntry(to: &refACLForFile,   isAllowRule: true, forAFolder: false, guid: uuid.guid, perms: Self.allPermsForFiles)
			try Self.addEntry(to: &refACLForFolder, isAllowRule: true, forAFolder: true,  guid: uuid.guid, perms: Self.allPermsForFolders)
		}
		
		init(denyEveryoneExecuteACLWithUUID uuid: UUID) throws {
			refACLForFolder = nil
			refACLForFile = acl_init(1)
			try Self.addEntry(to: &refACLForFile, isAllowRule: false, forAFolder: false, guid: uuid.guid, perms: [ACL_EXECUTE])
		}
		
		init(chaclConfig: ChaclConfigEntry, odNode: ODNode) throws {
			let permCount = Int32(chaclConfig.permissions.count)
			refACLForFile = acl_init(permCount /* This is a minimum; we could put 0 here. */)
			refACLForFolder = acl_init(permCount /* This is a minimum; we could put 0 here. */)
			
			let filePermsRO   = [ACL_READ_ATTRIBUTES, ACL_READ_EXTATTRIBUTES, ACL_READ_DATA]
			let folderPermsRO = [ACL_READ_ATTRIBUTES, ACL_READ_EXTATTRIBUTES, ACL_LIST_DIRECTORY, ACL_SEARCH]
			let filePermsWO   = [ACL_DELETE, ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_DATA, ACL_APPEND_DATA]
			let folderPermsWO = [ACL_DELETE, ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_ADD_FILE, ACL_ADD_SUBDIRECTORY, ACL_DELETE_CHILD]
			
			for perm in chaclConfig.permissions {
				let destRecordType: String
				let destRecordName: String
				switch perm.destination {
					case .user(let username):   destRecordType = kODRecordTypeUsers;  destRecordName = username
					case .group(let groupname): destRecordType = kODRecordTypeGroups; destRecordName = groupname
				}
				let record = try odNode.record(withRecordType: destRecordType, name: destRecordName, attributes: [kODAttributeTypeGUID])
				guard let destguid = try (record.values(forAttribute: kODAttributeTypeGUID).onlyElement as? String).flatMap({ UUID(uuidString: $0) })?.guid else {
					throw SimpleError(message: "zero or more than one value, or invalid UUID string for attribute kODAttributeTypeGUID for permission destination \(perm.destination); cannot continue.")
				}
				
				/* Might be a surprising way of doing things, but if the perm.rights
				 * enum type changes, we will fail here, whatever the change. */
				let isRW: Bool
				switch perm.rights {
					case .readonly:  isRW = false
					case .readwrite: isRW = true
				}
				
				try Self.addEntry(to: &refACLForFile,   isAllowRule: true, forAFolder: false, guid: destguid, perms: filePermsRO   + (isRW ? filePermsWO   : []))
				try Self.addEntry(to: &refACLForFolder, isAllowRule: true, forAFolder: true,  guid: destguid, perms: folderPermsRO + (isRW ? folderPermsWO : []))
			}
		}
		
		deinit {
			if let acl = refACLForFile   {acl_free(UnsafeMutableRawPointer(acl))}
			if let acl = refACLForFolder {acl_free(UnsafeMutableRawPointer(acl))}
		}
		
		/** Returns `true` if the ACL has been modified. */
		func addACLEntries(to acl: inout acl_t, isFolder: Bool, isRoot: Bool) throws -> Bool {
			guard let ref = isFolder ? refACLForFolder : refACLForFile else {return false}
			return try addACLEntries(to: acl, isRoot: isRoot, ref: ref)
		}
		
		private static func addEntry(to acl: inout acl_t!, isAllowRule: Bool, forAFolder: Bool, guid: guid_t, perms: [acl_perm_t]) throws {
			var aclEntry: acl_entry_t?
			guard acl_create_entry(&acl, &aclEntry) == 0 else {
				throw SimpleError(message: "cannot create ACL entry while init’ing a ACLConfig")
			}
			
			guard acl_set_tag_type(aclEntry, isAllowRule ? ACL_EXTENDED_ALLOW : ACL_EXTENDED_DENY) == 0 else {
				throw SimpleError(message: "cannot set tag type of ACL entry while init’ing a ACLConfig")
			}
			
			var guid = guid
			guard acl_set_qualifier(aclEntry, &guid) == 0 else {
				throw SimpleError(message: "cannot set qualifier of ACL entry while init’ing a ACLConfig")
			}
			
			var aclPermset: acl_permset_t!
			guard acl_get_permset(aclEntry, &aclPermset) == 0 else {
				throw SimpleError(message: "cannot get ACL entry permset while init’ing a ACLConfig")
			}
			for perm in perms {
				guard acl_add_perm(aclPermset, perm) == 0 else {
					throw SimpleError(message: "cannot add perm to permset")
				}
			}
			guard acl_set_permset(aclEntry, aclPermset) == 0 else {
				throw SimpleError(message: "cannot set ACL entry permset while init’ing a ACLConfig")
			}
			
			/* We do not set any flag on the files… Note a flagset can be set on
			 * the ACL and the ACL entry. We only set it on the ACL entry, both
			 * because it’s what we really want and also because I’m not sure what
			 * setting on the ACL directly does. */
			if forAFolder {
				var aclFlagset: acl_flagset_t!
				guard acl_get_flagset_np(aclEntry.flatMap({ UnsafeMutableRawPointer($0) }), &aclFlagset) == 0 else {
					throw SimpleError(message: "cannot get ACL entry flagset while init’ing a ACLConfig")
				}
				for flag in [ACL_ENTRY_FILE_INHERIT, ACL_ENTRY_DIRECTORY_INHERIT] {
					guard acl_add_flag_np(aclFlagset, flag) == 0 else {
						throw SimpleError(message: "cannot add flag to flagset")
					}
				}
				guard acl_set_flagset_np(aclEntry.flatMap({ UnsafeMutableRawPointer($0) }), aclFlagset) == 0 else {
					throw SimpleError(message: "cannot set ACL entry flagset while init’ing a ACLConfig")
				}
			}
		}
		
		/* Must be implicitely unwrapped because of weird interoperability w/ C. */
		private var refACLForFile: acl_t!
		private var refACLForFolder: acl_t!
		
		private func addACLEntries(to acl: acl_t, isRoot: Bool, ref: acl_t) throws -> Bool {
			var modified = false
			var acl: acl_t! = acl
			var currentRefACLEntry: acl_entry_t?
			var currentRefACLEntryId = ACL_FIRST_ENTRY.rawValue
			while acl_get_entry(ref, currentRefACLEntryId, &currentRefACLEntry) == 0 {
				let currentRefACLEntry = currentRefACLEntry! /* No error from acl_get_entry: the entry must be filled in and non-nil */
				defer {currentRefACLEntryId = ACL_NEXT_ENTRY.rawValue}
				
				/* Creating a new ACL entry in the destination ACL */
				var currentACLEntry: acl_entry_t?
				guard acl_create_entry(&acl, &currentACLEntry) == 0 else {
					throw SimpleError(message: "cannot create ACL entry while copying ACL entries")
				}
				modified = true
				
				/* Copying ACL entry tag */
				var currentRefACLEntryTagType = ACL_UNDEFINED_TAG
				guard acl_get_tag_type(currentRefACLEntry, &currentRefACLEntryTagType) == 0, acl_set_tag_type(currentACLEntry, currentRefACLEntryTagType) == 0 else {
					throw SimpleError(message: "cannot copy ACL entry tag type while copying ACL entries")
				}
				
				/* Copying ACL qualifier */
				guard let qualifer = acl_get_qualifier(currentRefACLEntry) else {
					throw SimpleError(message: "cannot copy ACL entry qualifier while copying ACL entries")
				}
				defer {acl_free(qualifer)}
				guard acl_set_qualifier(currentACLEntry, qualifer) == 0 else {
					throw SimpleError(message: "cannot copy ACL entry qualifier while copying ACL entries")
				}
				
				/* Copying ACL permset */
				var currentRefACLEntryPermset: acl_permset_t?
				guard acl_get_permset(currentRefACLEntry, &currentRefACLEntryPermset) == 0, acl_set_permset(currentACLEntry, currentRefACLEntryPermset) == 0 else {
					throw SimpleError(message: "cannot copy ACL entry permset while copying ACL entries")
				}
				
				/* Copying (and modifying if needed) flagset */
				var currentRefACLEntryFlagset: acl_flagset_t?
				guard acl_get_flagset_np(UnsafeMutableRawPointer(currentRefACLEntry), &currentRefACLEntryFlagset) == 0 else {
					throw SimpleError(message: "cannot copy ACL entry flagset while copying ACL entries")
				}
				/* We mark the permission as being inherited if needed. Actually
				 * changes the flagset of the ref ACL, but we do not care because we
				 * will always set it to the correct value (and we run on 1 thread
				 * only). */
				if !isRoot {acl_add_flag_np(currentRefACLEntryFlagset, ACL_ENTRY_INHERITED)}
				else       {acl_delete_flag_np(currentRefACLEntryFlagset, ACL_ENTRY_INHERITED)}
				guard acl_set_flagset_np(currentACLEntry.flatMap({ UnsafeMutableRawPointer($0) }), currentRefACLEntryFlagset) == 0 else {
					throw SimpleError(message: "cannot copy ACL entry flagset while copying ACL entries")
				}
			}
			return modified
		}
		
	}
	
}
