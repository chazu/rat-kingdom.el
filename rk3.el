;;; rk3.el --- Swarm orchestration for coding agents -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; Maintainer: Chaz Straney <chaz.straney@gmail.com>
;; URL: https://github.com/chazu/rat-kingdom.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, processes
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; rk3 runs a swarm of coding agents from inside Emacs: a king the user
;; talks to, workers in their own Git worktrees, and a tuplespace they
;; coordinate through.  DESIGN.md describes the whole system.
;;
;; So far only the tuplespace exists; see rk3-space.el.

;;; Code:

(require 'rk3-space)

(defgroup rk3 nil
  "Swarm orchestration for coding agents."
  :group 'tools
  :prefix "rk3-")

(provide 'rk3)
;;; rk3.el ends here
