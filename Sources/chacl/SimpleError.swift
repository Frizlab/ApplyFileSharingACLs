/*
 * SimpleError.swift
 * chacl
 *
 * Created by François Lamboley on 31/07/2020.
 */

import Foundation



public struct SimpleError : Error {
	
	public var message: String
	
	public init(message: String) {
		self.message = message
	}
	
}
